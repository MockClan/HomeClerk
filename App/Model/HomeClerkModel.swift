// HomeClerkModel: everything the window shows — the pipeline's state, what's in progress,
// activity, and Review's queue — and the pipeline events that change it.

import AppKit
import CoreSpotlight
import HomeClerkKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct Activity: Identifiable {
    enum Kind: String { case filed, review, duplicate, added, problem }

    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String
    let path: String?
    var engine: String? = nil
    var fallback = false
    var time = Date()
}

extension Activity {
    /// From the history log, as Activity shows earlier days.
    init(_ entry: HistoryLog.Entry) {
        self.init(kind: Kind(rawValue: entry.kind.rawValue) ?? .problem, title: entry.title, detail: entry.detail,
                  path: entry.path, engine: entry.engine, fallback: entry.fallback, time: entry.at)
    }
}

/// "Claude claude-sonnet-5-5" → "Claude"; "Apple on-device" → "Apple".
func engineShortName(_ engine: String) -> String {
    String(engine.split(separator: " ").first ?? Substring(engine))
}

/// A document HomeClerk is working on, keyed by its path in the inbox.
struct WorkItem: Identifiable {
    let id: String
    var stage: String
    var engine: String? = nil
    var replacedEngine: String? = nil   // the engine that failed before the fallback took over
    let started = Date()

    var name: String { (id as NSString).lastPathComponent }

    var stageText: String {
        switch stage {
        case "waiting": "Waiting for the scan to finish…"
        case "reading": "Reading the pages…"
        case "analyzing":
            switch (engine.map(engineShortName), replacedEngine.map(engineShortName)) {
            case let (now?, failed?): "\(failed) unavailable, analyzing with \(now)…"
            case let (now?, nil): "Analyzing with \(now)…"
            default: "Analyzing…"
            }
        case "filing": "Filing…"
        default: "Detected, getting ready…"
        }
    }
}

/// What HomeClerk last reported about Ollama, in the form the views show.
struct OllamaInfo: Equatable {
    let status: String   // ready, stopped, missing-model
    let model: String
    let role: String     // primary or fallback
}

@MainActor
@Observable
final class HomeClerkModel {
    static let shared = HomeClerkModel()

    struct ReviewDraft {
        var facets: DocumentFacets
        var folder: String
        var parts: [FacetDocument]
        var part: Int
    }
    struct FiledDraft {
        var original: DocumentIndex.Entry
        var facets: DocumentFacets
        var folder: String
        var originalFolder: String
    }
    @ObservationIgnored var reviewDrafts: [String: ReviewDraft] = [:]
    @ObservationIgnored var filedDrafts: [String: FiledDraft] = [:]
    @ObservationIgnored var lastReviewSelection = Set<String>()
    @ObservationIgnored var lastFiledDocumentID: String?
    var reviewDraftRevision = 0
    var activeDocumentActions = Set<String>()

    func beginDocumentAction(_ paths: [String]) -> Bool {
        guard activeDocumentActions.isDisjoint(with: paths) else { return false }
        activeDocumentActions.formUnion(paths)
        return true
    }
    func endDocumentAction(_ paths: [String]) { activeDocumentActions.subtract(paths) }
    func documentIsBusy(_ path: String) -> Bool { activeDocumentActions.contains(path) }
    func draftKey(_ documentID: String) -> String {
        (currentSettings ?? SettingsStore.app.load()).basePath.path + ":" + documentID
    }
    func confirmDiscardEdits() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "Switching documents keeps drafts. This action discards the affected changes."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Changes")
        return alert.runModal() == .alertSecondButtonReturn
    }

    enum State: Equatable { case starting, watching, paused, stopping, failed(String) }

    var state: State = .starting
    var inbox: URL?
    var organized: URL?
    var review: URL?
    var activity: [Activity] = []
    var filed = 0
    var needsReview = 0 { didSet { NSApp?.dockTile.badgeLabel = needsReview > 0 ? "\(needsReview)" : nil } }
    var duplicates = 0
    var errorDetails = ""
    var working: [WorkItem] = []
    var ollama: OllamaInfo?
    var ollamaStarting = false
    var ollamaProblem: String?
    var autoStartOllama = UserDefaults.standard.bool(forKey: DefaultsKey.startOllama) {
        didSet {
            UserDefaults.standard.set(autoStartOllama, forKey: DefaultsKey.startOllama)
            if autoStartOllama, ollama?.status == "stopped" { startOllama() }
        }
    }

    // View state for the window
    var dropTargeted = false
    var showErrorDetails = false

    var pending: [ReviewActions.PendingScan] = []
    /// A filed document to select when the Filed section next shows.
    var focusedDocument: String?
    /// The household profile, as Settings and the correction prompts edit it.
    var household = HouseholdProfile.empty
    /// Names seen on filed documents that the household doesn't know, asked about in Review.
    var noticed: [NoticedName] = []
    /// What a correction could teach HomeClerk, offered under the form that made it.
    var suggestion: Suggestion?
    /// Further suggestions from the same correction, asked one after another.
    var laterSuggestions: [Suggestion] = []
    /// Ollama's downloaded models, for Settings; nil until asked (or when Ollama isn't running).
    var ollamaModels: [OllamaModelInfo]?
    /// Models Ollama has in memory now; nil when Ollama can't be reached.
    var ollamaLoaded: [OllamaClient.LoadedModel]?
    /// Downloads in progress: model → (fraction done when known, Ollama's status line).
    var downloads: [String: (progress: Double?, status: String)] = [:]
    var downloadProblem: String?
    /// Scans set aside as duplicates, and filed documents past their keep period, for Tidy Up.
    var duplicateItems: [DuplicateItem] = []
    var expiredDocuments: [ExpiredDocument] = []
    /// Filed documents with too little to go on, for Tidy Up ▸ Needs Details.
    var needsDetails: [DocumentIndex.Entry] = []
    /// Copies in _originals of scans filed long ago — optional tidying, so not in the badge.
    var clearableOriginals: [ClearableOriginal] = []
    /// Copies from before HomeClerk kept filing records: cleared only after you confirm.
    var olderOriginals: [ClearableOriginal] = []
    @ObservationIgnored var originalsVerification: Task<([ClearableOriginal], [ClearableOriginal]), Never>?
    var tidyCount: Int { duplicateItems.count + expiredDocuments.count + needsDetails.count }
    /// Set with `focusedDocument` to open that document in Filed ready to edit.
    var editWhenFocused = false
    /// Sheets the menus open.
    var showTaxExport = false
    var showWelcome = false
    var showWhatsNew = false
    var showYearInReview = false
    /// Tidy Up's Library Health sheet, also opened from File ▸ Check Library Health.
    var showLibraryHealth = false
    /// Where the HomeClerk folder was when it couldn't be found at startup (moved or renamed in
    /// Finder, or on a drive that isn't connected).
    var missingFolder: URL?
    /// While Settings ▸ General ▸ Move… is moving the folder.
    var movingFolder = false
    /// Notifications waiting a moment to be combined, and the task that posts them.
    var notificationBatch: [(title: String, body: String, path: String, category: String)] = []
    var notificationFlush: Task<Void, Never>?
    var digestTask: Task<Void, Never>?
    /// This month's estimated Claude spending, for the limit banner.
    var claudeSpent: Decimal = 0
    /// Set by Go ▸ Search Documents to put the cursor in Search's field.
    var focusSearch = false
    /// Words for Search to look up when it next shows — from Spending's Show Documents, say.
    var searchRequest: String?
    /// What backs up the HomeClerk folder, once checked (nil until then).
    var backupCoverage: [BackupCheck.Coverage]?
    /// What can read documents here (a Claude key, Apple Intelligence, Ollama), checked at each start.
    var readers = Readers(hasClaudeKey: true, appleIntelligence: false, ollamaInstalled: false)
    /// Whether the rules in use are your copy (Settings ▸ Rules), and why it wasn't used if it's broken.
    var usingCustomTaxonomy = false
    var taxonomyProblem: String?
    /// Paused by you: stays paused across restarts until resumed.
    var stayPaused = false
    /// When each scan's analysis began, and by which engine, for timing models on this Mac.
    var analysisStarted: [String: (engine: String, at: Date)] = [:]
    /// The last library read, and what it was read from — see `library`.
    @ObservationIgnored var libraryCache: (key: String, library: DocumentLibrary)?
    @ObservationIgnored private var fullTextIndex: (folder: URL, index: FullTextIndex)?

    /// The text printed in filed documents, cached in the HomeClerk folder, for Search.
    var fullText: FullTextIndex {
        let folder = (currentSettings ?? SettingsStore.app.load()).basePath.appendingPathComponent(".homeclerk-cache")
        if let cached = fullTextIndex, cached.folder == folder { return cached.index }
        let index = FullTextIndex(folder: folder)
        fullTextIndex = (folder, index)
        return index
    }
    /// Which HomeClerk folder Activity's history was read from.
    @ObservationIgnored var historyLoadedFrom: URL?
    /// Which household.json `household` was read from, so a restart doesn't reread it needlessly.
    var householdLoadedFrom: URL?
    /// Published after committed library changes, including payment marks and archive switches.
    /// Invalidate immediately: consumers must never reuse a same-size, same-timestamp index.
    var documentsChanged = 0 {
        didSet { libraryCache = nil; refreshFinishing(); refreshReceiptDecisions() }
    }
    var receiptDecisionSnapshot = ReceiptDecisions.Snapshot.empty {
        didSet { receiptDecisionRevision += 1 }
    }
    @ObservationIgnored private var receiptDecisionRevision = 0
    /// The bill index for the current library and decisions, built once rather than on every
    /// redraw of the screens that read it.
    @ObservationIgnored private var billIndexCache: (key: String, index: BillIndex)?
    var receiptDecisionProblem: String?
    var receiptMatchIndex: BillIndex {
        let documents = library.documents   // refreshes libraryCache when the index changed
        let key = (libraryCache?.key ?? "") + "|\(receiptDecisionRevision)"
        if let cache = billIndexCache, cache.key == key { return cache.index }
        let index = BillIndex(documents, decisions: receiptDecisionSnapshot)
        billIndexCache = (key, index)   // not observed, so storing it while a view draws is fine
        return index
    }
    var unavailableReceiptDecisions: [ReceiptDecisions.Record] {
        let counts = Dictionary(grouping: library.documents, by: \.documentID).mapValues(\.count)
        return receiptDecisionSnapshot.records.filter { counts[$0.billID] != 1 || counts[$0.receiptID] != 1 }
    }
    func refreshReceiptDecisions() {
        let folder = (currentSettings ?? SettingsStore.app.load()).basePath
        do { receiptDecisionSnapshot = try ReceiptDecisions(folder: folder).snapshot(); receiptDecisionProblem = nil }
        catch { receiptDecisionSnapshot = .unavailable; receiptDecisionProblem = "Receipt decisions could not be read. Receipt matching is suspended; saved decisions were preserved. \(error)" }
    }

    @discardableResult
    func decideReceipt(_ confirmed: Bool?, proposal: ReceiptMatchProposal, undoManager: UndoManager?) -> String? {
        let folder = (currentSettings ?? SettingsStore.app.load()).basePath
        refreshReceiptDecisions()
        do {
            try FileOrganizer.requireInside(healthIndex.url, folder)
            _ = try healthIndex.loadValidated()
            libraryCache = nil
        } catch { return "The Library index could not be verified. No receipt decision was changed: \(error.localizedDescription)" }
        guard !documentIsBusy(proposal.bill.path), !documentIsBusy(proposal.receipt.path),
              receiptMatchIndex.proposals.contains(proposal), confirmed != true || proposal.canConfirm else {
            return "The documents or decision changed, or document work is running. Refresh and review this pair again."
        }
        return saveReceiptDecision(confirmed, billID: proposal.bill.documentID, receiptID: proposal.receipt.documentID,
            billName: (proposal.bill.path as NSString).lastPathComponent, receiptName: (proposal.receipt.path as NSString).lastPathComponent, undoManager: undoManager)
    }

    func resetUnavailableReceiptDecision(_ record: ReceiptDecisions.Record, undoManager: UndoManager?) -> String? {
        refreshReceiptDecisions()
        do {
            try FileOrganizer.requireInside(healthIndex.url, (currentSettings ?? SettingsStore.app.load()).basePath)
            _ = try healthIndex.loadValidated(); libraryCache = nil
        }
        catch { return "The Library index could not be verified. No decision changed: \(error.localizedDescription)" }
        guard unavailableReceiptDecisions.contains(where: { $0.id == record.id && $0.revision == record.revision }),
              !library.documents.contains(where: { ($0.documentID == record.billID || $0.documentID == record.receiptID) && documentIsBusy($0.path) }) else {
            return "This decision or its documents changed. Review it again before resetting."
        }
        return saveReceiptDecision(nil, billID: record.billID, receiptID: record.receiptID, undoManager: undoManager)
    }

    private func saveReceiptDecision(_ confirmed: Bool?, billID: String, receiptID: String,
                                     billName: String? = nil, receiptName: String? = nil, undoManager: UndoManager?) -> String? {
        let folder = (currentSettings ?? SettingsStore.app.load()).basePath
        let store = ReceiptDecisions(folder: folder)
        let before = library.payments(marks: paidMarks, decisions: receiptDecisionSnapshot)
        do {
            let change = try store.set(confirmed, billID: billID, receiptID: receiptID, billName: billName, receiptName: receiptName)
            undoManager?.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated {
                    guard (model.currentSettings ?? SettingsStore.app.load()).basePath == folder else {
                        model.record(.problem, "Couldn't undo receipt decision", "Switch back to the archive where this decision was made.", nil); return
                    }
                    let beforeUndo = model.library.payments(marks: model.paidMarks, decisions: model.receiptDecisionSnapshot)
                    do { try store.undo(change); model.documentsChanged += 1; model.syncChangedPayments(beforeUndo) }
                    catch { model.record(.problem, "Couldn't undo receipt decision", error.localizedDescription, nil) }
                }
            }
            undoManager?.setActionName(confirmed == true ? "Confirm Receipt Match" : confirmed == false ? "Reject Receipt Match" : "Reset Receipt Decision")
            documentsChanged += 1
            syncChangedPayments(before)
            return nil
        } catch { return error.localizedDescription }
    }
    private func syncChangedPayments(_ before: [String: BillPayment]) {
        let after = library.payments(marks: paidMarks, decisions: receiptDecisionSnapshot)
        for (path, payment) in after where before[path]?.isPaid != payment.isPaid { syncPaymentReminder(billPath: path) }
    }
    var finishingRepairs: [FinishingIssues.Record] = []
    var finishingProblem: String?
    var repairingDocuments = Set<String>()
    var showFinishingRepairs = false

    func refreshFinishing() {
        let settings = currentSettings ?? SettingsStore.app.load()
        do {
            let records = try FinishingIssues(folder: settings.basePath).load()
            let entries = Dictionary(grouping: library.documents, by: \.documentID)
            finishingRepairs = records.compactMap { record in
                guard let matches = entries[record.documentID], matches.count == 1 else { return nil }
                var current = record
                current.path = matches[0].path
                return current
            }.sorted { $0.updatedAt > $1.updatedAt }
            finishingProblem = nil
        } catch {
            finishingRepairs = []
            finishingProblem = "Couldn't read finishing repair history: \(error)"
        }
    }

    func canRetryFinishing(_ repair: FinishingIssues.Record) -> Bool {
        guard pipeline != nil, state != .stopping else { return false }
        let settings = currentSettings ?? SettingsStore.app.load()
        return repair.failures.contains { failure in
            switch failure.step {
            case .searchable: settings.makeSearchable
            case .tags: settings.applyFinderTags
            case .reminders: settings.createReminders
            }
        }
    }

    func retryFinishing(_ documentID: String) {
        guard !repairingDocuments.contains(documentID),
              finishingRepairs.contains(where: { $0.documentID == documentID }) else { return }
        guard let pipeline, state != .stopping else {
            record(.problem, "Couldn't retry finishing", "Wait for HomeClerk to finish starting or restarting, then retry.", nil)
            return
        }
        let matches = library.documents.filter { $0.documentID == documentID }
        guard matches.count == 1, let entry = matches.first else { return }
        let settings = currentSettings ?? SettingsStore.app.load()
        let file = URL(fileURLWithPath: entry.path)
        do { try FileOrganizer.requireInside(file, settings.outboxFolder) }
        catch { record(.problem, "Couldn't retry finishing", "\(error)", nil); return }
        guard beginDocumentAction([entry.path]) else { return }
        repairingDocuments.insert(documentID)
        Task {
            defer { repairingDocuments.remove(documentID); endDocumentAction([entry.path]); documentsChanged += 1; updateSpotlight() }
            do {
                let outcome = try await FinishingIssues(folder: settings.basePath).retry(documentID: documentID,
                    settings: settings, index: pipeline.index, duplicates: pipeline.duplicates)
                for warning in outcome.warnings { record(.problem, "Finishing needs attention", warning, file.path) }
                if outcome.warnings.isEmpty {
                    record(.added, "Finishing retry completed", "Enabled repair steps completed for \(file.lastPathComponent).", file.path)
                }
            } catch { record(.problem, "Couldn't retry finishing", "\(error)", file.path) }
        }
    }
    /// The window's section, remembered between launches.
    var section: Section = Section(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.selectedSection) ?? "") ?? .activity {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: DefaultsKey.selectedSection) }
    }

    private(set) var pipeline: HomeClerkPipeline?
    private var eventLoop: Task<Void, Never>?
    private var pendingFiles: [URL] = []
    private var ollamaProcess: Process?
    private var ollamaApp: NSRunningApplication?

    /// Loads the settings, taxonomy, and household profile, and starts watching the inbox.
    func start() {
        state = .starting
        working = []
        analysisStarted = [:]
        do {
            guard let taxonomyURL = builtInTaxonomyURL else {
                throw StartFailure(description: "taxonomy.json is missing from the app — rebuild it")
            }
            let store = SettingsStore.app
            let settings = store.load()
            // A folder that's gone isn't quietly replaced by an empty one: ask where it went
            if UserDefaults.standard.bool(forKey: DefaultsKey.setupComplete),
               !FileManager.default.fileExists(atPath: settings.basePath.path) {
                missingFolder = settings.basePath
                fail("Can't find the HomeClerk folder", details: settings.basePath.path)
                return
            }
            // Your rules (Settings ▸ Rules) when you have them, otherwise the built-in ones
            let loaded = try TaxonomyConfig.loadEffective(custom: settings.basePath.appendingPathComponent(TaxonomyConfig.fileName),
                                                          builtIn: taxonomyURL)
            let taxonomy = loaded.config
            usingCustomTaxonomy = loaded.usingCustom
            taxonomyProblem = loaded.problem

            // One stream, so events arrive in the order the pipeline sent them
            let (events, continuation) = AsyncStream.makeStream(of: PipelineEvent.self)
            let pipeline = try HomeClerkPipeline(settings: settings, taxonomy: taxonomy,
                localOnlyPolicy: { SettingsStore.app.load().localReadersOnly }) { continuation.yield($0) }
            self.pipeline = pipeline
            eventLoop = Task { [weak self] in
                for await event in events { self?.handle(event) }
            }
            Task {
                do {
                    try await pipeline.start()
                    // A restart (say, a settings change) doesn't undo Pause
                    if self.stayPaused { await pipeline.pause() }
                } catch {
                    self.fail("Couldn't watch the inbox", details: "\(error)")
                }
            }
        } catch {
            fail("Couldn't start HomeClerk", details: "\(error)")
        }
    }

    private func fail(_ message: String, details: String) {
        state = .failed(message)
        errorDetails = details
    }

    /// Stops watching and lets the current step finish. Returns false when nothing is running;
    /// otherwise calls `done` once it has stopped.
    func stop(done: @escaping @MainActor () -> Void) -> Bool {
        guard let pipeline else { return false }
        state = .stopping
        Task {
            await pipeline.stop()
            self.pipeline = nil
            self.eventLoop?.cancel()
            done()
        }
        return true
    }

    /// Stops picking up scans until `resume`; the one in progress finishes.
    func pause() {
        guard state == .watching, let pipeline else { return }
        state = .paused
        stayPaused = true
        Task { await pipeline.pause() }
    }

    func resume() {
        guard state == .paused, let pipeline else { return }
        state = .watching
        stayPaused = false
        Task {
            do { try await pipeline.resume() } catch { self.fail("Couldn't watch the inbox", details: "\(error)") }
        }
    }

    /// The menu bar icon for what HomeClerk is doing.
    var menuSymbol: String {
        switch state {
        case .watching where !working.isEmpty: "doc.text.magnifyingglass"
        case .watching: "tray.and.arrow.down"
        case .paused: "pause.circle"
        case .failed: "exclamationmark.triangle"
        case .starting, .stopping: "ellipsis.circle"
        }
    }

    /// The settings HomeClerk is running with: its preferences, and any environment overrides.
    var currentSettings: HomeClerkSettings? { pipeline?.settings }
    var healthIndex: DocumentIndex {
        pipeline?.index ?? DocumentIndex(url: SettingsStore.app.load().basePath.appendingPathComponent(DocumentIndex.fileName))
    }
    var healthDuplicates: DuplicateDetector? { pipeline?.duplicates }
    /// Runs a Library Health repair with watching paused, so no scan is filed mid-repair, then
    /// resumes if HomeClerk was watching before. (Paused by you, it stays paused.)
    func withWatchingPaused<T>(_ body: () async -> T) async -> T {
        let wasWatching = state == .watching
        if wasWatching { pause() }
        if let pipeline { await pipeline.pause() }
        let result = await body()
        if wasWatching { resume() }
        return result
    }

    var reviewActions: ReviewActions? { pipeline?.reviewActions() }

    /// Review actions that file by the given rules, rather than the ones watching started with.
    func reviewActions(using taxonomy: TaxonomyConfig) -> ReviewActions? { pipeline?.reviewActions(taxonomy: taxonomy) }

    /// Scans in Review being read again, and by which provider.
    var reading: [String: AIProvider] = [:]

    /// Reads a Review scan again with another provider; its new proposal shows when done.
    @discardableResult
    func readAgain(_ scan: URL, with provider: AIProvider) async -> Bool {
        if let reason = SettingsStore.app.load().readerPolicyProblem(for: provider) {
            record(.problem, scan.lastPathComponent, reason, nil)
            return false
        }
        guard state != .stopping, let pipeline, beginDocumentAction([scan.path]) else { return false }
        defer { endDocumentAction([scan.path]) }
        reading[scan.path] = provider
        defer { reading[scan.path] = nil; refreshReview() }
        do {
            let analysis = try await pipeline.reanalyze(scan, with: provider)
            return analysis.error == nil
        } catch {
            record(.problem, scan.lastPathComponent, "Couldn't read it again: \(error.localizedDescription)", nil)
            return false
        }
    }

    /// Document types, areas, and folder rules, for the correction form's pickers.
    var taxonomy: TaxonomyConfig? { pipeline?.taxonomy }

    /// Rereads _review; the Dock badge counts what's actually waiting there.
    func refreshReview() {
        pending = reviewActions?.pendingScans() ?? []
        needsReview = pending.count
    }

    /// Bills due and documents expiring in the next `days`, plus bills from the last month still
    /// unpaid. Paid bills are left out unless `includePaid`.
    func upcoming(days: Int, library: DocumentLibrary? = nil, includePaid: Bool = false) -> [UpcomingItem] {
        let library = library ?? self.library
        let items = library.upcoming(from: DocumentProcessor.localToday(), to: Self.day(days),
                                     payments: library.payments(marks: paidMarks, decisions: receiptDecisionSnapshot), overdueFrom: Self.day(-30))
        return includePaid ? items : items.filter { $0.payment?.isPaid != true }
    }

    /// Today plus `offset` days, as yyyy-MM-dd.
    nonisolated static func day(_ offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: .now)!
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Marks a bill paid or not paid by hand; nil goes back to matching receipts.
    /// The hand mark on a bill: true paid, false not paid, nil none (receipts decide).
    func paidMark(path: String) -> Bool? {
        library.documents.first { $0.path == path }.flatMap { paidMarks.mark(for: $0) }
    }

    func setPaid(_ paid: Bool?, path: String) {
        guard let bill = library.documents.first(where: { $0.path == path }) else { return }
        do {
            try paidMarks.set(paid, for: bill)
        } catch {
            record(.problem, (path as NSString).lastPathComponent, "Couldn't save whether it's paid: \(error.localizedDescription)", path)
            return
        }
        documentsChanged += 1
        syncPaymentReminder(billPath: path)
    }

    /// With Reminders on, ticks off a bill's "Pay …" reminder once it's paid — checked off, or paid by
    /// a receipt — and reopens it if it's marked not paid again.
    @ObservationIgnored private var paymentReminderTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    func syncPaymentReminder(billPath: String) {
        let settings = currentSettings ?? SettingsStore.app.load()
        guard settings.createReminders, let original = library.documents.first(where: { $0.path == billPath }) else { return }
        let documentID = original.documentID, id = UUID()
        let prior = paymentReminderTasks[documentID]?.task
        prior?.cancel()
        let task = Task {
            await prior?.value
            defer { if paymentReminderTasks[documentID]?.id == id { paymentReminderTasks[documentID] = nil } }
            let current = currentSettings ?? SettingsStore.app.load()
            guard !Task.isCancelled, current.createReminders, current.basePath == settings.basePath,
                  let bill = library.documents.first(where: { $0.documentID == documentID }) else { return }
            let paid = library.payments(marks: paidMarks, decisions: receiptDecisionSnapshot)[bill.path]?.isPaid ?? false
            do {
                try await Reminders.setPaymentDone(paid, bill: bill.facets, path: bill.path,
                    documentID: bill.documentID, inList: settings.remindersList)
            } catch is CancellationError {
            } catch {
                record(.problem, (bill.path as NSString).lastPathComponent, "Couldn't update its reminder: \(error.localizedDescription)", bill.path)
            }
        }
        paymentReminderTasks[documentID] = (id, task)
    }

    func find(_ query: String) -> [DocumentIndex.Entry] { library.find(query) }

    /// Paid calls, from usage.jsonl — readable before watching has started.
    func usage() -> UsageSummary {
        let settings = currentSettings ?? SettingsStore.app.load()
        return UsageSummary((try? UsageLedger.load(from: settings.basePath.appendingPathComponent(UsageLedger.fileName))) ?? [])
    }

    /// Stops and starts again, picking up changed settings.
    func restart() {
        if !stop(done: { HomeClerkModel.shared.start() }) { start() }
    }

    /// The settings as stored, without environment overrides — what Settings edits.
    func storedSettings() -> HomeClerkSettings { SettingsStore.app.load(environment: [:]) }

    private var pendingRestart: Task<Void, Never>?

    /// Saves changed settings and, once they've stopped changing for a moment, restarts watching.
    func apply(_ settings: HomeClerkSettings) {
        guard settings != storedSettings() else { return }
        let wasLocalOnly = storedSettings().localReadersOnly
        SettingsStore.app.save(settings)
        if settings.localReadersOnly && !wasLocalOnly {
            pendingRestart?.cancel()
            if state == .stopping { scheduleRestart() } else { restart() }
            return
        }
        scheduleRestart()
    }

    /// Restarts watching once changes have paused for a moment, so the next scan uses them.
    func scheduleRestart() {
        pendingRestart?.cancel()
        pendingRestart = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            restart()
        }
    }

    func addToInbox(_ urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard let inbox else { pendingFiles += pdfs; return }
        for file in pdfs {
            var dest = inbox.appendingPathComponent(file.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = inbox.appendingPathComponent("\(file.deletingPathExtension().lastPathComponent)_\(n).pdf")
                n += 1
            }
            do {
                let settings = currentSettings ?? SettingsStore.app.load()
                try FileOrganizer.requireInside(inbox, settings.basePath)
                try FileOrganizer.requireInside(dest, inbox)
                // The pipeline reports it as detected right away, so no row of its own here
                try FileManager.default.copyItem(at: file, to: dest)
            } catch {
                record(.problem, file.lastPathComponent, "Couldn't add it: \(error.localizedDescription)", nil)
            }
        }
    }

    /// Starts `ollama serve` (or the Ollama app, if that's how it's installed). A server this
    /// app starts is stopped when the app quits.
    func startOllama() {
        guard !ollamaStarting, ollamaProcess?.isRunning != true else { return }
        ollamaProblem = nil

        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama") {
            ollamaStarting = true
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: app, configuration: config) { running, error in
                Task { @MainActor in
                    if let error { HomeClerkModel.shared.ollamaFailed(error.localizedDescription) }
                    else { HomeClerkModel.shared.ollamaApp = running }
                }
            }
            return
        }

        guard let cli = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            ollamaProblem = "Ollama isn't installed. Install it with `brew install ollama` or from ollama.com."
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            let code = finished.terminationStatus
            Task { @MainActor in HomeClerkModel.shared.ollamaExited(code: code) }
        }
        do {
            try process.run()
            ollamaProcess = process
            ollamaStarting = true
        } catch {
            ollamaFailed(error.localizedDescription)
        }
    }

    /// Stops the Ollama server this app started, if any.
    func stopOllama() {
        ollamaApp?.terminate()
        ollamaApp = nil
        guard let process = ollamaProcess, process.isRunning else { return }
        ollamaProcess = nil
        process.terminate()
    }

    private func ollamaFailed(_ message: String) {
        ollamaStarting = false
        ollamaProblem = "Couldn't start Ollama: \(message)"
    }

    private func ollamaExited(code: Int32) {
        guard ollamaProcess != nil else { return }   // stopped on purpose
        ollamaProcess = nil
        // A server that was already running makes ours exit at once; the monitor reports that one
        if ollama?.status != "ready" { ollamaFailed("ollama serve exited with code \(code)") }
    }

    private func handle(_ event: PipelineEvent) {
        switch event {
        case let .problem(message):
            record(.problem, "Filing needs attention", message, nil)
        case let .ready(inbox, organized, review):
            self.inbox = inbox
            self.organized = organized
            self.review = review
            documentsChanged += 1
            loadHistory()
            state = .watching
            if stayPaused { state = .paused }   // paused for real once start-up finishes, below
            refreshReview()
            updateSpotlight()
            loadHousehold()
            refreshTidy()
            startWeeklyDigest()
            checkClaudeBudget()
            readers = Readers.detect()
            let waiting = pendingFiles
            pendingFiles = []
            addToInbox(waiting)
        case let .detected(source):
            if !working.contains(where: { $0.id == source.path }) {
                working.append(WorkItem(id: source.path, stage: "detected"))
            }
        case let .stage(source, stage, engine):
            if let i = working.firstIndex(where: { $0.id == source.path }) {
                if stage == .analyzing, let previous = working[i].engine, previous != engine {
                    working[i].replacedEngine = previous
                }
                working[i].stage = stage.rawValue
                if let engine { working[i].engine = engine }
                if stage == .analyzing, let engine { analysisStarted[source.path] = (engine, .now) }
            } else {
                working.append(WorkItem(id: source.path, stage: stage.rawValue, engine: engine))
            }
        case let .skipped(source), let .finished(source):
            finish(source)
        case let .ollama(status):
            ollama = OllamaInfo(status: status.state.rawValue, model: status.model, role: status.role.rawValue)
            if status.state != .stopped { ollamaStarting = false; ollamaProblem = nil }
            if status.state == .stopped, autoStartOllama { startOllama() }
        case let .filed(path, folder, source, engine, fallback):
            finish(source)
            filed += 1
            documentsChanged += 1
            updateSpotlight()
            refreshTidy()
            notice(path)
            let note = Bills.filingNote(for: path.path, in: library.documents, marks: paidMarks, decisions: receiptDecisionSnapshot)
            // A receipt that pays a bill ticks off the bill's reminder
            if let bill = receiptMatchIndex.receiptMatches.first(where: { $0.value == path.path })?.key {
                syncPaymentReminder(billPath: bill)
            }
            record(.filed, path.lastPathComponent, [folder, note].compactMap { $0 }.joined(separator: " — "), path.path,
                   engine: engine, fallback: fallback)
            notify("Filed in \(folder)", [path.lastPathComponent, note].compactMap { $0 }.joined(separator: "\n"), path.path,
                   category: Notify.filed)
        case let .review(path, reason, source, engine, fallback):
            finish(source)
            refreshReview()
            record(.review, path.lastPathComponent, reason, path.path, engine: engine, fallback: fallback)
            notify("Needs review", path.lastPathComponent, path.path, category: Notify.needsReview)
        case let .duplicate(path, original, source, engine, fallback):
            finish(source)
            duplicates += 1
            refreshTidy()
            record(.duplicate, path.lastPathComponent, "Already filed as \(original)", path.path, engine: engine, fallback: fallback)
            notify("Already filed", path.lastPathComponent, path.path, category: Notify.duplicate)
        }
    }

    /// A document is done (or gone): stop showing it as in progress, and note how long the model took.
    private func finish(_ source: URL) {
        working.removeAll { $0.id == source.path }
        if let started = analysisStarted.removeValue(forKey: source.path) {
            ModelTimings.record(engine: started.engine, seconds: Date.now.timeIntervalSince(started.at))
        }
    }

    /// Adds a row; an outcome also says which engine analyzed the document.
    /// One step of an undo. A step can fail — the file was moved or deleted since — and then
    /// Activity says so, rather than leaving you thinking it was undone.
    func undoStep(_ action: String, _ step: () throws -> Void) {
        do { try step() } catch {
            record(.problem, "Couldn't undo \(action)", error.localizedDescription, nil)
        }
    }

    func undoRefilings(_ refilings: [ReviewActions.Refiling], action: String, focus: String? = nil) {
        guard let actions = reviewActions else { return }
        let paths = refilings.flatMap { [$0.before.path, $0.after.path] }
        guard beginDocumentAction(paths) else { return }
        Task {
            defer { endDocumentAction(paths); documentsChanged += 1; updateSpotlight() }
            for refiling in refilings.reversed() {
                do {
                    try await actions.undo(refiling)
                    if let focus { focusedDocument = focus }
                } catch { record(.problem, "Couldn't undo \(action)", error.localizedDescription, nil) }
            }
        }
    }

    /// After a batch that carries on past failures: how many didn't make it, and why the first didn't.
    func reportSkipped(_ failures: [any Error], of total: Int, _ doing: String) {
        guard let first = failures.first else { return }
        record(.problem, "\(failures.count) of \(total) couldn't be \(doing)", first.localizedDescription, nil)
    }

    func record(_ kind: Activity.Kind, _ title: String, _ detail: String, _ path: String?,
                        engine: String? = nil, fallback: Bool = false) {
        activity.insert(Activity(kind: kind, title: title, detail: detail, path: path, engine: engine, fallback: fallback), at: 0)
        if activity.count > 500 { activity.removeLast(activity.count - 500) }
        history.append(HistoryLog.Entry(kind: HistoryLog.Entry.Kind(rawValue: kind.rawValue) ?? .problem, title: title,
                                        detail: detail, path: path, engine: engine, fallback: fallback))
    }

    /// The history log in the HomeClerk folder in use.
    var history: HistoryLog { HistoryLog(folder: (currentSettings ?? SettingsStore.app.load()).basePath) }

    /// Earlier days' activity, read once per HomeClerk folder (not again on every restart).
    func loadHistory() {
        let folder = (currentSettings ?? SettingsStore.app.load()).basePath
        guard historyLoadedFrom != folder else { return }
        historyLoadedFrom = folder
        let log = HistoryLog(folder: folder)
        log.trim()
        activity = log.recent().map(Activity.init)
    }

    private func notify(_ title: String, _ body: String, _ path: String, category: String) {
        queueNotification(title, body, path, category: category)
        checkClaudeBudget()
    }
}

/// Notification kinds and their buttons.
enum Notify {
    static let filed = "filed", needsReview = "review", duplicate = "duplicate", summary = "summary", weekly = "weekly"
    static let billDue = "bill-due"
    static let reveal = "reveal", open = "open", review = "show-review", showUpcoming = "show-upcoming", markPaid = "mark-paid"

    static var categories: Set<UNNotificationCategory> {
        let reveal = UNNotificationAction(identifier: reveal, title: "Show in Finder")
        let open = UNNotificationAction(identifier: open, title: "Open")
        let review = UNNotificationAction(identifier: review, title: "Review", options: .foreground)
        return [
            UNNotificationCategory(identifier: filed, actions: [open, reveal], intentIdentifiers: []),
            UNNotificationCategory(identifier: needsReview, actions: [review, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: duplicate, actions: [reveal], intentIdentifiers: []),
            UNNotificationCategory(identifier: summary, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: billDue,
                                   actions: [UNNotificationAction(identifier: markPaid, title: "Mark as Paid"),
                                             UNNotificationAction(identifier: showUpcoming, title: "Show Upcoming", options: .foreground)],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: weekly,
                                   actions: [UNNotificationAction(identifier: showUpcoming, title: "Show Upcoming", options: .foreground)],
                                   intentIdentifiers: [])
        ]
    }
}

struct StartFailure: Error, CustomStringConvertible {
    let description: String
}

extension HomeClerkModel {
    /// What HomeClerk is doing, for the Activity subtitle and the sidebar's status line.
    var statusText: String {
        switch state {
        case .starting: "Starting…"
        case .watching where !working.isEmpty:
            working.count == 1 ? "Processing 1 document…" : "Processing \(working.count) documents…"
        case .watching: "Watching \((inbox?.path as NSString?)?.abbreviatingWithTildeInPath ?? "the inbox")"
        case .paused: "Paused — new scans wait in the inbox"
        case .stopping: "Stopping…"
        case .failed: "Not running"
        }
    }
}
