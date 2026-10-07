import Foundation
import os

/// HomeClerk, running: watches the inbox and files each scan, reporting what it does through
/// `events`. Built from the user's settings, taxonomy.json, and household profile.
public final class HomeClerkPipeline: @unchecked Sendable {
    public let settings: HomeClerkSettings
    public let taxonomy: TaxonomyConfig
    /// Shared with the review actions, so both write through the same in-memory copies
    public let index: DocumentIndex
    public let duplicates: DuplicateDetector
    let processor: DocumentProcessor
    let watcher: InboxWatcher
    let ollama: OllamaMonitor?
    let events: PipelineEventHandler
    private let queue: AsyncStream<URL>
    private let queueContinuation: AsyncStream<URL>.Continuation
    private var processing: Task<Void, Never>?
    private let gate = PauseGate()
    private let profile: HouseholdProfile
    private let ledger: UsageLedger
    private let lock: FolderLock
    private let localOnlyPolicy: (@Sendable () -> Bool)?

    public init(settings: HomeClerkSettings, taxonomy: TaxonomyConfig,
                localOnlyPolicy: (@Sendable () -> Bool)? = nil, events: @escaping PipelineEventHandler) throws {
        self.settings = settings
        self.taxonomy = taxonomy
        self.events = events
        self.localOnlyPolicy = localOnlyPolicy
        let profile = try HouseholdProfile.loadOrEmpty(from: settings.householdProfilePath)
        let ledger = UsageLedger(url: settings.basePath.appendingPathComponent(UsageLedger.fileName))
        self.profile = profile
        self.ledger = ledger

        let primary = Self.analyzer(settings.aiProvider, settings: settings, taxonomy: taxonomy, profile: profile, ledger: ledger, localOnlyPolicy: localOnlyPolicy)
        let fallback = settings.fallbackProvider.flatMap { $0 == settings.aiProvider ? nil : $0 }.map {
            Self.analyzer($0, settings: settings, taxonomy: taxonomy, profile: profile, ledger: ledger, localOnlyPolicy: localOnlyPolicy)
        }
        let analyzer = ResilientFacetAnalyzer(primary: primary, fallback: fallback, onAnalyzing: { pdf, model in
            events(.stage(source: pdf, stage: .analyzing, engine: model))
        })

        index = DocumentIndex(url: settings.basePath.appendingPathComponent(DocumentIndex.fileName))
        duplicates = DuplicateDetector(duplicatesFolder: settings.duplicatesFolder,
                                       hammingThreshold: settings.duplicateHammingThreshold)
        processor = DocumentProcessor(settings: settings, taxonomy: taxonomy, analyzer: analyzer, duplicates: duplicates,
                                      index: index, finisher: Finisher(settings), events: events)

        lock = FolderLock(folder: settings.basePath)
        (queue, queueContinuation) = AsyncStream.makeStream(of: URL.self)
        let continuation = queueContinuation
        watcher = InboxWatcher(inbox: settings.inboxFolder, debounceSeconds: settings.debounceSeconds, events: events,
                               enqueue: { continuation.yield($0) })
        ollama = OllamaMonitor.role(for: settings).map {
            OllamaMonitor(baseURL: settings.analysisOllamaURL, model: settings.ollamaModel, role: $0, events: events,
                          session: settings.localReadersOnly ? LocalReaderTransport.session : .shared)
        }
    }

    /// Review actions that file through this pipeline's index and duplicate list.
    public func reviewActions() -> ReviewActions { reviewActions(taxonomy: taxonomy) }

    /// The same, filing by other rules — ones just edited, before watching restarts with them.
    public func reviewActions(taxonomy: TaxonomyConfig) -> ReviewActions {
        ReviewActions(settings: settings, taxonomy: taxonomy, finisher: Finisher(settings), index: index, duplicates: duplicates, warnings: { [events] message in events(.problem(message)) })
    }

    /// Reads a scan in Review again with a provider you chose, and
    /// replaces its proposal and reason with the new reading. The scan stays in Review to be filed.
    @discardableResult
    public func reanalyze(_ scan: URL, with provider: AIProvider) async throws -> FacetAnalysis {
        let operation = try DocumentOperations.acquire([scan])
        defer { operation.release() }
        try FileOrganizer.requireInside(settings.reviewFolder, settings.basePath)
        try FileOrganizer.requireInside(scan, settings.reviewFolder)
        let analyzer = Self.analyzer(provider, settings: settings, taxonomy: taxonomy, profile: profile, ledger: ledger, localOnlyPolicy: localOnlyPolicy)
        let (text, pages) = try await TextRecognizer.text(ofPDF: scan, strict: false)
        var analysis = await analyzer.analyze(ocrText: text, pageCount: pages, pdf: scan)
        analysis.documentID = ReviewProposal.load(for: scan)?.documentID
        try Task.checkCancellation()
        let reason: String
        if let error = analysis.error {
            reason = "\(analyzer.modelName) couldn't read it: \(error)"
        } else {
            let lowest = analysis.documents.map(\.confidence).min() ?? 0
            reason = "Read again by \(analyzer.modelName): \(Int((lowest * 100).rounded()))% sure"
                + (analysis.documents.count > 1 ? ", \(analysis.documents.count) documents." : ".")
            try ReviewProposal.save(analysis, for: scan)
        }
        try (reason + "\n\n" + analysis.summary).write(to: ReviewProposal.reasonURL(for: scan), atomically: true, encoding: .utf8)
        return analysis
    }

    public var ledgerURL: URL { settings.basePath.appendingPathComponent(UsageLedger.fileName) }

    /// The analyzer for a provider, with these settings.
    public static func analyzer(_ provider: AIProvider, settings: HomeClerkSettings, taxonomy: TaxonomyConfig,
                                profile: HouseholdProfile, ledger: UsageLedger?,
                                localOnlyPolicy: (@Sendable () -> Bool)? = nil) -> any FacetAnalyzer {
        if let localOnlyPolicy {
            let initial = Self.analyzer(provider, settings: settings, taxonomy: taxonomy, profile: profile, ledger: ledger)
            return LiveReaderPolicyAnalyzer(modelName: initial.modelName, isPaid: initial.isPaid, policy: localOnlyPolicy) { enabled in
                var effective = settings
                effective.localReadersOnly = settings.localReadersOnly || enabled
                return Self.analyzer(provider, settings: effective, taxonomy: taxonomy, profile: profile, ledger: ledger)
            }
        }
        if let reason = settings.readerPolicyProblem(for: provider) {
            return UnavailableAnalyzer(modelName: provider.rawValue, reason: reason)
        }
        switch provider {
        case .ollama:
            return OllamaFacetAnalyzer(baseURL: settings.analysisOllamaURL, model: settings.ollamaModel,
                                       sendImages: settings.sendPageImages, maxImagePages: settings.maxImagePages,
                                       taxonomy: taxonomy, profile: profile,
                                       session: settings.localReadersOnly ? LocalReaderTransport.session : .shared,
                                       unloadMinutes: settings.ollamaUnloadMinutes)
        case .apple:
            return AppleFacetAnalyzer(model: settings.appleModel, sendImages: settings.sendPageImages,
                                      maxImagePages: settings.maxImagePages, taxonomy: taxonomy, profile: profile)
        case .claude:
            let key = Keychain.readAPIKey()
            guard let key else {
                return UnavailableAnalyzer(modelName: "Claude \(settings.claudeModel)",
                                           reason: "No Anthropic API key — add one in HomeClerk ▸ Settings")
            }
            let claude = ClaudeFacetAnalyzer(apiKey: key, model: settings.claudeModel, effort: settings.claudeEffort,
                                             sendPDF: settings.sendPageImages, taxonomy: taxonomy, profile: profile, ledger: ledger)
            guard settings.claudeMonthlyLimit > 0, let ledger else { return claude }
            return BudgetedAnalyzer(claude, ledger: ledger, limit: Decimal(settings.claudeMonthlyLimit))
        }
    }

    public func start() async throws {
        // They hold personal documents: only this account may list or read them
        var folders = [settings.basePath, settings.inboxFolder, settings.outboxFolder, settings.reviewFolder,
                       settings.duplicatesFolder]
        if settings.preserveOriginals { folders.append(settings.originalsFolder) }
        for folder in folders { try FileOrganizer.requireInside(folder, settings.basePath) }
        for folder in folders { try PrivateFolder.secure(folder) }
        try lock.acquire()
        Legacy.migrateFolder(settings.basePath)
        // Interrupted filings are finished or rolled back before watching starts. One that can't be
        // finished safely is left exactly as it is and reported; it doesn't stop HomeClerk watching.
        let recovery = FilingTransaction(settings: settings, index: index).recoverWhatIsSafe()
        for problem in recovery.preserved {
            events(.problem("An interrupted filing couldn't be finished, so its files were kept as they are. "
                            + "See Tidy Up ▸ Library Health. (\(problem))"))
        }
        if recovery.recovered > 0 {
            do {
                _ = try BackfillApplier.rebuildDuplicateIndex(index, duplicates: duplicates, organized: settings.outboxFolder)
            } catch {
                events(.problem("After recovering interrupted filings, the duplicate list couldn't be rebuilt: \(error.localizedDescription)"))
            }
        }
        events(.ready(inbox: settings.inboxFolder, organized: settings.outboxFolder, review: settings.reviewFolder))
        let (queue, processor, watcher, gate, events) = (self.queue, self.processor, self.watcher, self.gate, self.events)
        // One document at a time, in the order they became ready
        processing = Task {
            for await file in queue {
                await gate.wait()
                guard !Task.isCancelled else { break }
                await processor.process(file)
                events(.finished(source: file))
                await watcher.finished(file)
            }
        }
        try await watcher.start()
        await ollama?.start()
    }

    /// Stops picking up scans: the one being processed finishes, and the rest wait in the inbox
    /// (or the queue) until `resume`.
    public func pause() async {
        await watcher.stop()
        await gate.close()
    }

    public func resume() async throws {
        await gate.open()
        try await watcher.start()
    }

    public func stop() async {
        await watcher.stop()
        await ollama?.stop()
        queueContinuation.finish()
        processing?.cancel()
        await gate.open()   // a paused loop must wake to see it's cancelled
        // Let the current step finish (cancelled work ends within a second or two)
        await processing?.value
        processing = nil
        lock.release()
    }
}

/// Keeps a second copy of HomeClerk from watching the same folder: both would pick up each scan,
/// analyzing (and paying for) it twice and fighting over the file.
final class FolderLock: @unchecked Sendable {
    struct Held: Error, CustomStringConvertible {
        var description: String { "Another copy of HomeClerk (or the older DocuSort) is already watching this folder. Quit it, then reopen HomeClerk." }
    }

    let url: URL
    private var descriptor: Int32 = -1
    private var legacyDescriptor: Int32 = -1
    private let mutex = NSLock()

    init(folder: URL) { url = folder.appendingPathComponent(".homeclerk.lock") }

    func acquire() throws {
        try mutex.withLock {
            guard descriptor < 0 else { return }
            let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
            // Released by the system if the app quits or crashes, so it can't go stale
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw Held() }
            // The app's old name used its own lock file; hold that too, if it's there
            let legacy = url.deletingLastPathComponent().appendingPathComponent(Legacy.lockName).path
            if FileManager.default.fileExists(atPath: legacy) {
                let old = open(legacy, O_RDWR | O_CLOEXEC)
                if old >= 0, flock(old, LOCK_EX | LOCK_NB) != 0 { close(old); flock(fd, LOCK_UN); close(fd); throw Held() }
                legacyDescriptor = old
            }
            descriptor = fd
        }
    }

    func release() {
        mutex.withLock {
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
            if legacyDescriptor >= 0 {
                flock(legacyDescriptor, LOCK_UN)
                close(legacyDescriptor)
                legacyDescriptor = -1
            }
        }
    }
}

/// Holds the processing loop while HomeClerk is paused.
actor PauseGate {
    private var closed = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var isClosed: Bool { closed }

    func close() { closed = true }

    func open() {
        closed = false
        let resumed = waiting
        waiting = []
        for continuation in resumed { continuation.resume() }
    }

    /// Returns at once when open; otherwise when `open` is next called.
    func wait() async {
        guard closed else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}

/// Stands in for a provider that can't run (e.g. no API key), so the fallback takes over.
struct UnavailableAnalyzer: FacetAnalyzer {
    let modelName: String
    let reason: String
    var isPaid: Bool { false }
    func analyze(ocrText: String, pageCount: Int, pdf: URL) async -> FacetAnalysis { .failed(reason) }
}
