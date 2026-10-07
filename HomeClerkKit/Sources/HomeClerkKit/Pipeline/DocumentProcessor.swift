import CryptoKit
import Foundation
import os

/// Takes one scan from the inbox to its outcome: OCR → analyze → file (or split, review, or set
/// aside as a duplicate) → finish. Each step is the same as the original version's,
/// including the reasons written beside scans sent to review.
public actor DocumentProcessor {
    let settings: HomeClerkSettings
    let analyzer: any FacetAnalyzer
    let router: FilingRouter
    let names: FilenameBuilder
    let organizer: FileOrganizer
    let duplicates: DuplicateDetector
    let index: DocumentIndex
    let finisher: Finisher
    let events: PipelineEventHandler
    let today: @Sendable () -> String
    private let log = Logger(subsystem: "com.mockclan.homeclerk", category: "processor")

    public init(settings: HomeClerkSettings, taxonomy: TaxonomyConfig, analyzer: any FacetAnalyzer,
                duplicates: DuplicateDetector, index: DocumentIndex, finisher: Finisher,
                events: @escaping PipelineEventHandler, today: @escaping @Sendable () -> String = DocumentProcessor.localToday) {
        self.settings = settings
        self.analyzer = analyzer
        router = FilingRouter(taxonomy)
        names = FilenameBuilder(taxonomy)
        organizer = FileOrganizer(outbox: settings.outboxFolder)
        self.duplicates = duplicates
        self.index = index
        self.finisher = finisher
        self.events = events
        self.today = today
    }

    /// Today's date where the user is, yyyy-MM-dd.
    public static func localToday() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public func process(_ file: URL) async {
        guard FileOrganizer.isInside(settings.inboxFolder, settings.basePath),
              FileOrganizer.isInside(file, settings.inboxFolder) else {
            events(.problem("Skipped a scan outside Inbox or containing a symbolic link"))
            return
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            log.warning("A scan disappeared before processing")
            events(.skipped(source: file))
            return
        }
        do {
            try await processExisting(file)
        } catch is CancellationError {
            log.info("Stopped while processing a scan; it stays in the inbox")
            return
        } catch {
            log.error("Unhandled error processing a scan: \(error.localizedDescription, privacy: .private)")
            if FilingTransaction(settings: settings, index: index).isPending(source: file) {
                events(.problem("Filing failed; source preserved for recovery: \(error.localizedDescription)"))
            }
            else { sendToReview(file, reason: "Unhandled exception: \(error.localizedDescription)") }
        }
    }

    private func processExisting(_ file: URL) async throws {
        // The same file dropped in twice is caught before any work (or API cost)
        let sha256 = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        if let match = duplicates.exactDuplicate(sha256: sha256) {
            sendToDuplicates(file, original: match, why: "identical file")
            return
        }

        if settings.preserveOriginals { copyToOriginals(file) }

        // Nothing can be read until someone types the password, in Review
        if PDFTools.isLocked(file) {
            sendToReview(file, reason: PDFTools.lockedReason)
            return
        }

        events(.stage(source: file, stage: .reading, engine: nil))
        let ocrText: String, pageCount: Int
        do {
            (ocrText, pageCount) = try await TextRecognizer.text(ofPDF: file, strict: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            sendToReview(file, reason: "PDF rendering failed: \(error)")
            return
        }
        try Task.checkCancellation()

        // Retries and fallback happen inside the analyzer, which reports the "analyzing" stage
        let analysis = await analyzer.analyze(ocrText: ocrText, pageCount: pageCount, pdf: file)
        // Quitting cancels the request; the scan stays in the inbox for next time instead of going to review
        try Task.checkCancellation()
        if let error = analysis.error {
            sendToReview(file, reason: error)
            return
        }

        if let problem = FacetDocument.pageCoverageProblem(analysis.documents, pageCount: pageCount) {
            sendToReview(file, reason: "Page ranges need review: \(problem). No documents were filed.", proposal: analysis)
            return
        }

        // Fallback models are less accurate, so their results must clear a higher bar
        let threshold = analysis.usedFallback ? settings.fallbackMinConfidence : settings.minConfidenceThreshold
        if let lowest = analysis.documents.map(\.confidence).filter({ $0 < threshold }).min() {
            let fallbackNote = analysis.usedFallback
                ? " (fallback \(analysis.model); primary failed: \(analysis.primaryError ?? ""))" : ""
            sendToReview(file, reason: "Confidence \(Self.percent(lowest)) below threshold \(Self.percent(threshold))"
                + fallbackNote + ".\n\n\(analysis.summary)\n\n"
                + "Run `HomeClerk review` to file it as proposed, open it, or choose another folder.",
                proposal: analysis)
            return
        }

        if analysis.documents.count == 1 {
            let document = analysis.documents[0]
            if let match = duplicates.nearDuplicate(ocrText: ocrText, facets: document.facets) {
                sendToDuplicates(file, original: match, why: "same text and same vendor, date, person, and amount",
                                 analyzedBy: analysis)
                return
            }
            let destination = try await fileDocument(file, original: file, document, analysis)
            // Register only after filing succeeded, so a failure can't strand a rescan in _duplicates
            duplicates.register(ocrText: ocrText, sha256: sha256, facets: document.facets,
                                label: relativeToOrganized(destination))
        } else if await splitAndFile(file, analysis) {
            // The whole scan's text spans several documents, so only an identical file matches later
            duplicates.register(ocrText: ocrText, sha256: sha256, facets: nil, label: "\(file.lastPathComponent) (split)")
        }
    }

    private func fileDocument(_ source: URL, original: URL, _ document: FacetDocument, _ analysis: FacetAnalysis) async throws -> URL {
        try await fileDocuments(source, documents: [document], analysis: analysis, splitting: false)[0]
    }

    private func fileDocuments(_ source: URL, documents: [FacetDocument], analysis: FacetAnalysis,
                               splitting: Bool) async throws -> [URL] {
        events(.stage(source: source, stage: .filing, engine: nil))
        var reserved = Set<String>()
        let outputs = try documents.map { document in
            let destination = try organizer.destination(folder: router.folder(for: document.facets),
                filename: names.build(document.facets), reserved: reserved)
            reserved.insert(destination.path)
            let entry = DocumentIndex.Entry(path: destination.path, source: source.lastPathComponent,
                pages: [document.firstPage, document.lastPage], model: analysis.model,
                confidence: document.confidence, summary: analysis.summary, facets: document.facets)
            return FilingTransaction.Output(destination: destination, entry: entry,
                pages: splitting ? document.firstPage...document.lastPage : nil)
        }
        try Task.checkCancellation()
        let operation = try DocumentOperations.acquire([source] + outputs.map(\.destination))
        defer { operation.release() }
        let result = try FilingTransaction(settings: settings, index: index).execute(source: source, outputs: outputs)
        for warning in result.warnings { events(.problem("Filing saved; cleanup needs attention: \(warning)")) }
        for (output, document) in zip(outputs, documents) {
            let outcome = await finisher.finish(output.destination, facets: document.facets, today: today(), documentID: output.entry.documentID)
            outcome.warnings.forEach { events(.problem($0)) }
        }
        for warning in result.recordOriginalFiling(settings: settings) { events(.problem(warning)) }
        for (output, document) in zip(outputs, documents) {
            events(.filed(path: output.destination, folder: router.folder(for: document.facets), source: source,
                engine: analysis.model, fallback: analysis.usedFallback))
        }
        return outputs.map(\.destination)
    }

    private func splitAndFile(_ file: URL, _ analysis: FacetAnalysis) async -> Bool {
        do {
            _ = try await fileDocuments(file, documents: analysis.documents, analysis: analysis, splitting: true)
            return true
        } catch is CancellationError { return false }
        catch {
            log.error("Split filing failed: \(error.localizedDescription, privacy: .private)")
            // Keep the source at the journal's recorded path if rollback needs startup recovery.
            if FilingTransaction(settings: settings, index: index).isPending(source: file) {
                events(.problem("Split filing failed; source preserved for recovery: \(error.localizedDescription)"))
            }
            else { sendToReview(file, reason: "Split filing failed; original preserved. \(error.localizedDescription)", proposal: analysis) }
            return false
        }
    }

    private func sendToDuplicates(_ file: URL, original: String, why: String, analyzedBy: FacetAnalysis? = nil) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileOrganizer.requireInside(settings.basePath, settings.basePath)
            try FileOrganizer.requireInside(settings.duplicatesFolder, settings.basePath)
            try FileManager.default.createDirectory(at: settings.duplicatesFolder, withIntermediateDirectories: true)
            let destination = FileOrganizer.unique(settings.duplicatesFolder.appendingPathComponent(file.lastPathComponent))
            try FileManager.default.moveItem(at: file, to: destination)
            events(.duplicate(path: destination, original: original, source: file, engine: analyzedBy?.model,
                              fallback: analyzedBy?.usedFallback == true))
            try "Duplicate of: \(original)\nWhy: \(why)\n"
                .appending("If this is actually a different document, choose Not a Duplicate in HomeClerk ▸ Tidy Up.")
                .write(to: ReviewProposal.reasonURL(for: destination), atomically: true, encoding: .utf8)
            // Kept so "Not a Duplicate" can offer the model's proposal in Review
            if let analyzedBy, analyzedBy.error == nil { try? ReviewProposal.save(analyzedBy, for: destination) }
        } catch {
            log.error("Failed to move a duplicate: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func copyToOriginals(_ file: URL) {
        do {
            try FileOrganizer.requireInside(settings.basePath, settings.basePath)
            try FileOrganizer.requireInside(settings.originalsFolder, settings.basePath)
            try Originals.preserve(file, in: settings.originalsFolder)
        } catch {
            log.warning("Could not preserve the original: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// - Parameters:
    ///   - proposal: Saved beside the scan so it can be filed as proposed.
    ///   - analyzedBy: The analysis, when there's one but nothing to propose.
    private func sendToReview(_ file: URL, reason: String, proposal: FacetAnalysis? = nil, analyzedBy: FacetAnalysis? = nil) {
        let firstLine = String(reason.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
        do {
            try FileOrganizer.requireInside(settings.basePath, settings.basePath)
            try FileOrganizer.requireInside(settings.reviewFolder, settings.basePath)
            try FileManager.default.createDirectory(at: settings.reviewFolder, withIntermediateDirectories: true)
            guard FileManager.default.fileExists(atPath: file.path) else {
                // The file disappeared first — write the reason anyway so it isn't silently lost
                let tombstone = settings.reviewFolder
                    .appendingPathComponent("\(file.deletingPathExtension().lastPathComponent)_missing.reason.txt")
                try "Original file was not found at processing time.\n\n\(reason)"
                    .write(to: tombstone, atomically: true, encoding: .utf8)
                return
            }
            let destination = FileOrganizer.unique(settings.reviewFolder.appendingPathComponent(file.lastPathComponent))
            try FileManager.default.moveItem(at: file, to: destination)
            try reason.write(to: ReviewProposal.reasonURL(for: destination), atomically: true, encoding: .utf8)
            let analysis = proposal ?? analyzedBy
            events(.review(path: destination, reason: firstLine, source: file, engine: analysis?.model,
                           fallback: analysis?.usedFallback == true))
            if let proposal { try ReviewProposal.save(proposal, for: destination) }
        } catch {
            log.error("Failed to send a scan to review: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func relativeToOrganized(_ url: URL) -> String {
        FileOrganizer.relativePath(url, in: settings.outboxFolder) ?? url.lastPathComponent
    }

    /// 0.625 → "63%"
    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}
