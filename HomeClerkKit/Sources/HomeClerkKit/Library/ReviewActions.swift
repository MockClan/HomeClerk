import CryptoKit
import Foundation

/// What can be done with a scan in _review. Filing goes through the same steps as the pipeline
/// — folder rules, file name, text layer, tags, reminders, index, and duplicate registration —
/// and removes the scan's .reason.txt and .proposal.json.
public struct ReviewActions: Sendable {
    let settings: HomeClerkSettings
    let taxonomy: TaxonomyConfig
    let router: FilingRouter
    let names: FilenameBuilder
    let organizer: FileOrganizer
    let finisher: Finisher
    let index: DocumentIndex
    let duplicates: DuplicateDetector
    let warnings: @Sendable (String) -> Void

    public init(settings: HomeClerkSettings, taxonomy: TaxonomyConfig, finisher: Finisher, index: DocumentIndex,
                duplicates: DuplicateDetector, warnings: @escaping @Sendable (String) -> Void = { _ in }) {
        self.settings = settings
        self.taxonomy = taxonomy
        router = FilingRouter(taxonomy)
        names = FilenameBuilder(taxonomy)
        organizer = FileOrganizer(outbox: settings.outboxFolder)
        self.finisher = finisher
        self.index = index
        self.duplicates = duplicates
        self.warnings = warnings
    }

    /// Validate the managed root too: a symlinked _review/Organized must not redefine the boundary.
    func requireManaged(_ url: URL, in folder: URL) throws {
        try FileOrganizer.requireInside(folder, settings.basePath)
        try FileOrganizer.requireInside(url, folder)
    }

    /// One scan waiting in _review, with why it's there and the model's proposal, if any.
    public struct PendingScan: Identifiable, Sendable {
        public var url: URL
        public var reason: String
        public var analysis: FacetAnalysis?
        public var id: String { url.path }

        /// The single document the model proposed; nil without a proposal or when it found several.
        public var document: FacetDocument? { analysis?.documents.count == 1 ? analysis?.documents.first : nil }
    }

    public func pendingScans() -> [PendingScan] {
        let files = (try? FileManager.default.contentsOfDirectory(at: settings.reviewFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "pdf" && FileOrganizer.isInside($0, settings.reviewFolder) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { scan in
                let reason = (try? String(contentsOf: ReviewProposal.reasonURL(for: scan), encoding: .utf8))
                    .map { String($0.split(separator: "\n", omittingEmptySubsequences: false).first ?? "") }
                return PendingScan(url: scan, reason: reason ?? "No reason recorded", analysis: ReviewProposal.load(for: scan))
            }
    }

    /// Where a proposal would be filed: (folder, file name).
    public func destination(_ facets: DocumentFacets) -> (folder: String, name: String) {
        (router.folder(for: facets), names.build(facets))
    }

    /// Where facets would be filed: the rules' folder, or `folder` when one was chosen.
    public func destination(_ facets: DocumentFacets, folder: String?) -> (folder: String, name: String) {
        let (ruled, name) = destination(facets)
        return (folder.flatMap { $0.isEmpty ? nil : $0 } ?? ruled, name)
    }

    /// Files a scan with details you corrected, in the rules' folder or the one you chose.
    @discardableResult
    public func fileEdited(_ scan: URL, facets: DocumentFacets, folder: String?, analysis: FacetAnalysis?,
                           confidence: Double) async throws -> Filing {
        let (target, name) = destination(facets, folder: folder)
        return try await file(scan, folder: target, name: name, facets: facets, analysis: analysis, confidence: confidence)
    }

    /// A filed document's details before and after a correction, so it can be undone.
    public struct Refiling: Sendable {
        public var before: DocumentIndex.Entry
        public var after: DocumentIndex.Entry
    }

    /// Corrects a filed document: renames and moves it to match `facets` (or into `folder`), and
    /// updates its Finder tags, its index entry, and its duplicate fingerprint.
    @discardableResult
    public func refile(_ entry: DocumentIndex.Entry, facets: DocumentFacets, folder: String?) async throws -> Refiling {
        let from = URL(fileURLWithPath: entry.path)
        let operation = try DocumentOperations.acquire([from])
        defer { operation.release() }
        try requireManaged(from, in: settings.outboxFolder)
        guard FileOrganizer.isInside(from, settings.outboxFolder) else { throw FileOrganizer.OutsideOrganized() }
        guard var current = DocumentLibrary.load(index).documents.first(where: { $0.documentID == entry.documentID }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        // Index serialization rounds timestamps; compare all version/content fields without that
        // irrelevant precision difference in a freshly appended caller's in-memory entry.
        current.filedAt = entry.filedAt
        guard current == entry else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "This document changed since editing began. Reload its details before saving."])
        }
        try PaidMarks(url: settings.basePath.appendingPathComponent(PaidMarks.fileName)).migrateLegacyMark(for: entry)
        let (target, name) = destination(facets, folder: folder)
        let wanted = settings.outboxFolder.appendingPathComponent(FileOrganizer.sanitizeFolder(target))
            .appendingPathComponent(FileOrganizer.sanitizeFile(name.lowercased().hasSuffix(".pdf") ? name : name + ".pdf"))
        let to = wanted.standardizedFileURL.path == from.standardizedFileURL.path
            ? from : try organizer.destination(folder: target, filename: name)
        let destinationOperation = to == from ? nil : try DocumentOperations.acquire([to])
        defer { destinationOperation?.release() }
        var after = entry
        after.path = to.path
        after.facets = facets
        after.corrected = after.corrected || facets != entry.facets
        let result = try FilingTransaction(settings: settings, index: index).execute(source: from,
            outputs: [.init(destination: to, entry: after)])
        result.warnings.forEach(warnings)
        after = result.entries[0]
        try move(entry, to: after)
        await syncReminders(from: entry, to: after)
        return Refiling(before: entry, after: after)
    }

    /// Puts a corrected document back as it was.
    public func undo(_ refiling: Refiling) async throws {
        let current = URL(fileURLWithPath: refiling.after.path), original = URL(fileURLWithPath: refiling.before.path)
        let operation = try DocumentOperations.acquire([current, original])
        defer { operation.release() }
        try requireManaged(current, in: settings.outboxFolder)
        try requireManaged(original, in: settings.outboxFolder)
        if current.standardizedFileURL.path != original.standardizedFileURL.path {
            try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: original.path) else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: original.path])
            }
        }
        let result = try FilingTransaction(settings: settings, index: index).execute(source: current,
            outputs: [.init(destination: original, entry: refiling.before)])
        result.warnings.forEach(warnings)
        try move(refiling.after, to: result.entries[0])
        await syncReminders(from: refiling.after, to: result.entries[0])
    }

    private func syncReminders(from old: DocumentIndex.Entry, to new: DocumentIndex.Entry) async {
        // Include past dates for exact migration of reminders created before today.
        let previous = FinishingPlan.reminders(old.facets, filePath: old.path, today: "0001-01-01",
            expirationLeadDays: settings.expirationReminderLeadDays)
        let outcome = await finisher.finish(URL(fileURLWithPath: new.path), facets: new.facets,
            today: DocumentProcessor.localToday(), documentID: new.documentID, steps: [.reminders],
            previousReminders: previous, synchronizeReminders: true)
        outcome.warnings.forEach(warnings)
    }

    /// Records a document's new place and details: tags, index, and duplicate fingerprint.
    private func move(_ old: DocumentIndex.Entry, to new: DocumentIndex.Entry) throws {
        let url = URL(fileURLWithPath: new.path)
        if settings.applyFinderTags {
            try? (url as NSURL).setResourceValue(FinishingPlan.finderTags(new.facets), forKey: .tagNamesKey)
        }
        duplicates.unregister(label: label(URL(fileURLWithPath: old.path)))
        let sha256 = (try? Data(contentsOf: url)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? ""
        duplicates.register(ocrText: Finisher.text(of: url), sha256: sha256, facets: new.facets, label: label(url))
    }

    /// A filed document's path inside Organized, as the duplicate list names it.
    func label(_ url: URL) -> String {
        FileOrganizer.relativePath(url, in: settings.outboxFolder) ?? url.lastPathComponent
    }

    /// Every folder a document can be filed in: the taxonomy's plus any already in Organized.
    public func folders() -> [String] {
        var folders = Set(taxonomy.rules.map(\.folder))
        let existing = (try? FileManager.default.contentsOfDirectory(at: settings.outboxFolder,
                                                                     includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for url in existing where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            folders.insert(url.lastPathComponent)
        }
        return folders.sorted()
    }

    /// What filing a scan from review changed, so it can be undone.
    public struct Filing: Sendable {
        public var scan: URL
        public var destination: URL
        var reason: String?
        var proposal: FacetAnalysis?
        var duplicateLabel: String?
    }

    /// Puts a filed scan back in _review with its reason and proposal, and forgets it in the
    /// duplicate list. Its text layer and tags stay — both are harmless.
    @discardableResult
    public func undo(_ filing: Filing) throws -> URL {
        let operation = try DocumentOperations.acquire([filing.scan, filing.destination])
        defer { operation.release() }
        try FileManager.default.createDirectory(at: settings.reviewFolder, withIntermediateDirectories: true)
        try requireManaged(filing.destination, in: settings.outboxFolder)
        try requireManaged(filing.scan, in: settings.reviewFolder)
        let back = FileOrganizer.unique(filing.scan)
        try FileManager.default.copyItem(at: filing.destination, to: back)
        if let reason = filing.reason { try reason.write(to: ReviewProposal.reasonURL(for: back), atomically: true, encoding: .utf8) }
        if let proposal = filing.proposal { try ReviewProposal.save(proposal, for: back) }
        try FileManager.default.removeItem(at: filing.destination)
        if let label = filing.duplicateLabel { duplicates.unregister(label: label) }
        return back
    }

    /// Files the scan where the model proposed, with the model's facets.
    @discardableResult
    public func fileAsProposed(_ scan: URL, document: FacetDocument, analysis: FacetAnalysis) async throws -> Filing {
        let (folder, name) = destination(document.facets)
        return try await file(scan, folder: folder, name: name, facets: document.facets, analysis: analysis,
                              confidence: document.confidence)
    }

    /// Files the scan in a folder you chose. With a proposal it keeps the proposed name and facets;
    /// without one, the scan keeps its current name and gets no tags or reminders.
    @discardableResult
    public func fileInFolder(_ scan: URL, folder: String, document: FacetDocument?, analysis: FacetAnalysis?) async throws -> Filing {
        guard let document else {
            return try await file(scan, folder: folder, name: scan.lastPathComponent, facets: nil, analysis: nil, confidence: 0)
        }
        return try await file(scan, folder: folder, name: names.build(document.facets), facets: document.facets,
                              analysis: analysis, confidence: document.confidence)
    }

    /// Moves the scan back to the inbox so it's analyzed again.
    @discardableResult
    public func sendBackToInbox(_ scan: URL) throws -> URL {
        let operation = try DocumentOperations.acquire([scan])
        defer { operation.release() }
        try requireManaged(scan, in: settings.reviewFolder)
        try requireManaged(settings.inboxFolder, in: settings.inboxFolder)
        try FileManager.default.createDirectory(at: settings.inboxFolder, withIntermediateDirectories: true)
        let destination = FileOrganizer.unique(settings.inboxFolder.appendingPathComponent(scan.lastPathComponent))
        try FileManager.default.moveItem(at: scan, to: destination)
        ReviewProposal.deleteSidecars(for: scan)
        return destination
    }

    func file(_ scan: URL, folder: String, name: String, facets: DocumentFacets?, analysis: FacetAnalysis?,
              confidence: Double, source: String? = nil) async throws -> Filing {
        let operation = try DocumentOperations.acquire([scan])
        defer { operation.release() }
        try requireManaged(scan, in: settings.reviewFolder)
        let sha256 = SHA256.hash(data: try Data(contentsOf: scan)).map { String(format: "%02x", $0) }.joined()
        let reason = try? String(contentsOf: ReviewProposal.reasonURL(for: scan), encoding: .utf8)
        let proposal = ReviewProposal.load(for: scan)
        let destination = try organizer.destination(folder: folder, filename: name)
        let destinationOperation = try DocumentOperations.acquire([destination])
        defer { destinationOperation.release() }
        let entry = DocumentIndex.Entry(documentID: proposal?.documentID ?? UUID().uuidString,
            path: destination.path, source: source ?? "review:\(scan.lastPathComponent)", pages: [],
            model: analysis?.model ?? "", confidence: confidence, summary: analysis?.summary ?? "",
            facets: facets ?? DocumentFacets())
        let result = try FilingTransaction(settings: settings, index: index).execute(source: scan,
            outputs: [.init(destination: destination, entry: entry)], deleteSidecars: true)
        result.warnings.forEach(warnings)
        var filing = Filing(scan: scan, destination: destination, reason: reason, proposal: proposal)

        let outcome = await finisher.finish(destination, facets: entry.facets, today: DocumentProcessor.localToday(), documentID: entry.documentID)
        outcome.warnings.forEach(warnings)
        guard let facets else {
            result.recordOriginalFiling(settings: settings).forEach(warnings)
            return filing
        }
        let label = label(destination)
        duplicates.register(ocrText: Finisher.text(of: destination), sha256: sha256, facets: facets, label: label)
        filing.duplicateLabel = label
        result.recordOriginalFiling(settings: settings).forEach(warnings)
        return filing
    }
}
