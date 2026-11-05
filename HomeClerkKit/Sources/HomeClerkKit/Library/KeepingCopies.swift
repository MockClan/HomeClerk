import Foundation

/// Choosing which of two copies of one paper to keep — whichever is the better scan. Nothing is
/// overwritten: the copy you don't keep goes to the Trash, and undo brings it back.
extension ReviewActions {
    public struct LibraryActionError: Error, LocalizedError {
        public let errorDescription: String?
        public init(_ message: String) { errorDescription = message }

        static let outOfDate = LibraryActionError("That list is out of date — a document in it changed. Look again in a moment.")
    }

    /// One filed copy kept and the other moved to the Trash, and the kept one's rename, if any.
    public struct KeptCopy: Sendable {
        public var kept: DocumentIndex.Entry
        var trashed: TrashedFile
        var renamed: Refiling?
    }

    /// A file moved to the Trash, and where it came back from.
    struct TrashedFile: Sendable {
        var inTrash: URL
        var original: URL
        var facets: DocumentFacets?
    }

    /// Keeps `keep` and moves `extra` to the Trash. A kept copy named with the "_2" HomeClerk adds
    /// when a name is taken gets the plain name when that's the name its details give it and it's
    /// now free — renamed as Edit Details would, so its tags, index entry, and reminders follow.
    public func keep(_ keep: DocumentIndex.Entry, removing extra: DocumentIndex.Entry) async throws -> KeptCopy {
        let keptURL = URL(fileURLWithPath: keep.path), extraURL = URL(fileURLWithPath: extra.path)
        guard keptURL.standardizedFileURL != extraURL.standardizedFileURL else { throw LibraryActionError("Choose two different copies.") }
        let trashed: TrashedFile
        do {
            let operation = try DocumentOperations.acquire([keptURL, extraURL])
            defer { operation.release() }
            try requireManaged(keptURL, in: settings.outboxFolder)
            try requireManaged(extraURL, in: settings.outboxFolder)
            try requireCurrent([keep, extra])
            trashed = try moveToTrash(extraURL, facets: extra.facets)
        }
        forgetFiled(extraURL)
        var kept = KeptCopy(kept: keep, trashed: trashed, renamed: nil)
        let (folder, name) = destination(keep.facets, folder: FileOrganizer.relativePath(keptURL.deletingLastPathComponent(),
                                                                                          in: settings.outboxFolder))
        if let plain = Self.withoutNumber(keptURL), plain.lastPathComponent == name,
           !FileManager.default.fileExists(atPath: plain.path) {
            do {
                let renamed = try await refile(keep, facets: keep.facets, folder: folder)
                kept.renamed = renamed
                kept.kept = renamed.after
            } catch {
                // The copy that went to the Trash comes back, so nothing is left half done
                try? restore(trashed)
                throw error
            }
        }
        return kept
    }

    /// Puts both copies back as they were.
    public func undo(_ kept: KeptCopy) async throws {
        if let renamed = kept.renamed { try await undo(renamed) }
        try restore(kept.trashed)
    }

    /// "Statement_2.pdf" → "Statement.pdf"; nil when there's no number to drop.
    static func withoutNumber(_ url: URL) -> URL? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let match = stem.firstMatch(of: /^(.+)_\d+$/) else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(String(match.1)).appendingPathExtension(url.pathExtension)
    }

    /// A scan set aside as a duplicate put in place of the filed copy, and how to put it back.
    public struct ReplacedCopy: Sendable {
        public var filed: URL
        var scan: URL
        /// The filed copy it replaced, in the Trash.
        var replaced: TrashedFile
        /// The scan's notes, in the Trash.
        var notes: [TrashedFile]
    }

    /// The scan set aside is the better one: it takes the filed copy's place — same name, folder,
    /// details, and tags, made searchable — and the filed copy goes to the Trash. Not for a whole
    /// pile set aside because every document in it was filed: it isn't any one of them.
    public func keepScanInstead(_ item: DuplicateItem) async throws -> ReplacedCopy {
        guard !item.wholePile else { throw LibraryActionError("This scan holds several documents, so it can't take one document's place.") }
        guard let filed = item.original else { throw LibraryActionError("The filed copy has moved.") }
        let operation = try DocumentOperations.acquire([item.url, filed])
        defer { operation.release() }
        try requireManaged(item.url, in: settings.duplicatesFolder)
        try requireManaged(filed, in: settings.outboxFolder)
        guard let entry = DocumentLibrary.load(index).documents.first(where: {
            URL(fileURLWithPath: $0.path).standardizedFileURL == filed.standardizedFileURL
        }) else { throw LibraryActionError.outOfDate }
        let replaced = try moveToTrash(filed, facets: entry.facets)
        do {
            try FileManager.default.moveItem(at: item.url, to: filed)
        } catch {
            try? FileManager.default.moveItem(at: replaced.inTrash, to: filed)
            throw error
        }
        let outcome = await finisher.finish(filed, facets: entry.facets, today: DocumentProcessor.localToday(),
                                            documentID: entry.documentID, steps: [.searchable, .tags])
        outcome.warnings.forEach(warnings)
        rememberFingerprint(filed, facets: entry.facets)
        var notes: [TrashedFile] = []
        for note in [ReviewProposal.reasonURL(for: item.url), ReviewProposal.proposalURL(for: item.url)]
        where FileManager.default.fileExists(atPath: note.path) {
            if let trashed = try? moveToTrash(note, facets: nil) { notes.append(trashed) }
        }
        return ReplacedCopy(filed: filed, scan: item.url, replaced: replaced, notes: notes)
    }

    /// Puts the filed copy back, and the scan (with its notes) back in _duplicates.
    public func undo(_ replaced: ReplacedCopy) throws {
        let operation = try DocumentOperations.acquire([replaced.filed, replaced.scan])
        defer { operation.release() }
        try requireManaged(replaced.filed, in: settings.outboxFolder)
        try requireManaged(replaced.scan, in: settings.duplicatesFolder)
        guard !FileManager.default.fileExists(atPath: replaced.scan.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: replaced.scan.path])
        }
        try FileManager.default.moveItem(at: replaced.filed, to: replaced.scan)
        try FileManager.default.moveItem(at: replaced.replaced.inTrash, to: replaced.filed)
        rememberFingerprint(replaced.filed, facets: replaced.replaced.facets)
        for note in replaced.notes { try? FileManager.default.moveItem(at: note.inTrash, to: note.original) }
    }

    // MARK: Shared by keeping, combining, and replacing

    /// Each document is still the one at its path, as the list showing it was made from.
    func requireCurrent(_ entries: [DocumentIndex.Entry]) throws {
        let byPath = Dictionary(DocumentLibrary.load(index).documents.map { ($0.path, $0.documentID) }, uniquingKeysWith: { $1 })
        for entry in entries where byPath[entry.path] != entry.documentID { throw LibraryActionError.outOfDate }
    }

    func moveToTrash(_ url: URL, facets: DocumentFacets?) throws -> TrashedFile {
        var inTrash: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &inTrash)
        guard let inTrash else { throw CocoaError(.fileWriteUnknown) }
        return TrashedFile(inTrash: inTrash as URL, original: url, facets: facets)
    }

    /// Brings a filed document back from the Trash, into the Library and the duplicate list again.
    func restore(_ file: TrashedFile) throws {
        let operation = try DocumentOperations.acquire([file.original])
        defer { operation.release() }
        try requireManaged(file.original, in: settings.outboxFolder)
        guard !FileManager.default.fileExists(atPath: file.original.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: file.original.path])
        }
        try FileManager.default.moveItem(at: file.inTrash, to: file.original)
        rememberFiled(file.original, facets: file.facets)
    }

    /// Rewrites a filed PDF in place, so its Finder tags and other attributes stay with it.
    func replaceContents(of url: URL, with data: Data) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".replacing-\(UUID().uuidString).pdf")
        try PrivateFile.write(data, to: temp)
        do { _ = try FileManager.default.replaceItemAt(url, withItemAt: temp) } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    func rememberFingerprint(_ url: URL, facets: DocumentFacets?) {
        duplicates.unregister(label: label(url))
        guard let data = try? Data(contentsOf: url) else { return }
        duplicates.register(ocrText: Finisher.text(of: url), sha256: BackfillApplier.sha256(data), facets: facets, label: label(url))
    }
}
