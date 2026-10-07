import Foundation
import PDFKit

/// An explicit, read-only archive audit. Repair rechecks evidence before changing metadata.
public enum LibraryHealth {
    public enum Kind: String, Sendable { case unindexed, missing, staleDuplicate, pendingOperation, finishing, unsafe, unreadable }
    public struct Issue: Identifiable, Equatable, Sendable {
        public var id: String { kind.rawValue + ":" + path }
        public let kind: Kind
        public let path: String
        public let title: String
        public let detail: String
        public var preview: String? = nil
        public var affectedPaths: [String] = []
        public var entry: DocumentIndex.Entry? = nil
        public var label: String? = nil
        public var operationID: String? = nil
    }
    public struct Report: Sendable {
        public var issues: [Issue] = []
        public var checkedPDFs = 0
        public init() {}
    }
    public struct MetadataUndo: Sendable {
        public let before: DocumentIndex.Entry?
        public let after: DocumentIndex.Entry
    }
    public struct Result: Sendable {
        public var undo: MetadataUndo? = nil
        public var recovered = false
    }
    struct Changed: Error, LocalizedError {
        var errorDescription: String? { "The archive changed since this preview. Refresh Library Health and review it again." }
    }
    static func key(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
    static func latest(_ entries: [DocumentIndex.Entry]) -> [String: DocumentIndex.Entry] {
        entries.reduce(into: [:]) { $0[key($1.path)] = $1 }
    }
    static func listedPath(_ file: URL, under root: URL) -> URL {
        // macOS enumeration may return /private/var for a root supplied as /var. Preserve the
        // caller's root spelling without resolving a child's symlink before safety validation.
        for prefix in [root.resolvingSymlinksInPath().path + "/", root.standardizedFileURL.path + "/"] {
            if file.standardizedFileURL.path.hasPrefix(prefix) {
                return root.appendingPathComponent(String(file.standardizedFileURL.path.dropFirst(prefix.count)))
            }
        }
        return file
    }

    public static func scan(settings: HomeClerkSettings, index: DocumentIndex) -> Report {
        var report = Report()
        func problem(_ path: URL, _ error: any Error, kind: Kind = .unreadable) {
            report.issues.append(.init(kind: kind, path: path.path, title: kind == .unsafe ? "Unsafe archive path" : "Could not inspect archive data",
                detail: String(describing: error)))
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: settings.basePath.path) else {
            problem(settings.basePath, CocoaError(.fileReadNoSuchFile)); return report
        }
        do {
            for root in [settings.outboxFolder, settings.reviewFolder, settings.duplicatesFolder, settings.basePath.appendingPathComponent(".homeclerk-operations")] {
                try FileOrganizer.requireInside(root, settings.basePath)
                if fm.fileExists(atPath: root.path), try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            try FileOrganizer.requireInside(index.url, settings.basePath)
        } catch { problem(settings.basePath, error, kind: .unsafe); return report }
        let entries: [DocumentIndex.Entry]
        do { entries = try index.loadValidated() }
        catch { problem(index.url, error); return report }
        let current = latest(entries)
        let byID = entries.reduce(into: [String: DocumentIndex.Entry]()) { $0[$1.documentID] = $1 }
        // Old rename paths remain in append-only history; they are not missing current documents.
        let active = current.values.filter { entry in
            !entry.removed && byID[entry.documentID]?.removed != true &&
            (byID[entry.documentID].map { key($0.path) == key(entry.path) } == true || fm.fileExists(atPath: entry.path))
        }
        var inReview = Set<String>()
        if fm.fileExists(atPath: settings.reviewFolder.path) {
            do {
                for file in try fm.contentsOfDirectory(at: settings.reviewFolder, includingPropertiesForKeys: nil) where file.pathExtension.lowercased() == "pdf" {
                    try FileOrganizer.requireInside(file, settings.reviewFolder)
                    try FileOrganizer.requireInside(ReviewProposal.proposalURL(for: file), settings.reviewFolder)
                    if let id = ReviewProposal.load(for: file)?.documentID { inReview.insert(id) }
                }
            } catch { problem(settings.reviewFolder, error) }
        }
        for entry in active.sorted(by: { $0.path < $1.path }) {
            let file = URL(fileURLWithPath: entry.path)
            do {
                try FileOrganizer.requireInside(file, settings.outboxFolder)
                if !fm.fileExists(atPath: file.path) {
                    if inReview.contains(entry.documentID) { continue }
                    report.issues.append(.init(kind: .missing, path: entry.path, title: "PDF is no longer there",
                        detail: "The Library has a record for this PDF, but there's no file at that path. If you moved it in Finder, move it back and refresh. If it's gone for good — deleted, or filed again as a new copy when it was re-processed — remove the record.",
                        preview: "Remove this record from the Library, so it no longer shows in Filed, Search, Upcoming, or Spending. No PDF is touched (there isn't one), and its history is kept. Undo brings the record back.",
                        affectedPaths: [entry.path], entry: entry))
                } else if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile != true {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
            } catch { problem(file, error, kind: .unsafe) }
        }
        for group in Dictionary(grouping: active.filter { fm.fileExists(atPath: $0.path) }, by: \.documentID).values where group.count > 1 {
            report.issues.append(.init(kind: .unreadable, path: group.sorted { $0.path < $1.path }[0].path,
                title: "Document identity appears at multiple paths", detail: "Keep all copies and review the index manually. Automatic identity repair would guess which document is authoritative."))
        }
        if fm.fileExists(atPath: settings.outboxFolder.path), let files = fm.enumerator(at: settings.outboxFolder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsPackageDescendants],
            errorHandler: { url, error in problem(url, error); return false }) {
            for case let listed as URL in files {
                let file = listedPath(listed, under: settings.outboxFolder)
                if Task.isCancelled { return report }
                do {
                    try FileOrganizer.requireInside(file, settings.outboxFolder)
                    guard file.pathExtension.lowercased() == "pdf", try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                    report.checkedPDFs += 1
                    let prior = current[key(file.path)]
                    if prior == nil || prior?.removed == true {
                        report.issues.append(.init(kind: .unindexed, path: file.path, title: "PDF is absent from the Library",
                            detail: "The PDF is in Organized but has no active Library record.",
                            preview: prior == nil ? "Add a Library record with unknown details for manual correction. Keep the PDF at its current path. No AI request, OCR, or reminder is created. Undo removes only the new record." : "Restore this PDF's prior Library record and details. Keep the PDF at its current path. Undo hides the record again.",
                            affectedPaths: [file.path], entry: prior))
                    }
                } catch { files.skipDescendants(); problem(file, error, kind: .unsafe) }
            }
        }
        do {
            for label in Set(try DuplicateDetector.recordedLabels(in: settings.duplicatesFolder)).sorted() {
                let file = settings.outboxFolder.appendingPathComponent(label)
                do {
                    guard !label.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    try FileOrganizer.requireInside(file, settings.outboxFolder)
                    if !fm.fileExists(atPath: file.path) {
                        report.issues.append(.init(kind: .staleDuplicate, path: file.path, title: "Duplicate match points to a missing PDF",
                            detail: "A new scan could be treated as a duplicate of a document no longer present.",
                            preview: "Remove duplicate fingerprints for this missing path. Keep all PDFs and other duplicate matches. Future scans can be filed again.",
                            affectedPaths: [file.path], label: label))
                    }
                } catch { problem(file, error, kind: .unsafe) }
            }
        } catch { problem(settings.duplicatesFolder.appendingPathComponent(DuplicateDetector.indexFileName), error) }
        let recoveryRoot = settings.basePath.appendingPathComponent(".homeclerk-operations")
        if fm.fileExists(atPath: recoveryRoot.path) {
            do {
                // Hidden files Finder or iCloud leave there (.DS_Store, .icloud placeholders) aren't operations
                for folder in try fm.contentsOfDirectory(at: recoveryRoot, includingPropertiesForKeys: nil)
                    .filter({ !$0.lastPathComponent.hasPrefix(".") }).sorted(by: { $0.path < $1.path }) {
                    do {
                        try FileOrganizer.requireInside(folder, recoveryRoot)
                        guard UUID(uuidString: folder.lastPathComponent) != nil else { throw CocoaError(.fileReadCorruptFile) }
                        let journalURL = folder.appendingPathComponent("journal.json")
                        try FileOrganizer.requireInside(journalURL, recoveryRoot)
                        let journal = try JSONDecoder().decode(FilingTransaction.Journal.self, from: Data(contentsOf: journalURL))
                        let source = URL(fileURLWithPath: journal.source)
                        let sourceRoot = [settings.inboxFolder, settings.reviewFolder, settings.outboxFolder].first { FileOrganizer.isInside(source, $0) }
                        guard journal.id == folder.lastPathComponent, !journal.parts.isEmpty, let sourceRoot else { throw CocoaError(.fileReadCorruptFile) }
                        try FileOrganizer.requireInside(sourceRoot, settings.basePath)
                        try FileOrganizer.requireInside(source, sourceRoot)
                        for part in journal.parts {
                            try FileOrganizer.requireInside(URL(fileURLWithPath: part.destination), settings.outboxFolder)
                            guard part.entry.path == part.destination, part.entry.operationID == journal.id else { throw CocoaError(.fileReadCorruptFile) }
                        }
                        let committed = journal.parts.allSatisfy { part in entries.contains { $0.operationID == journal.id && $0.path == part.destination } }
                        report.issues.append(.init(kind: .pendingOperation, path: folder.path, title: "Interrupted filing needs recovery",
                            detail: "Source: \(journal.source)\nOutputs:\n" + journal.parts.map(\.destination).joined(separator: "\n"),
                            preview: committed ? "Verify committed outputs and retire the unchanged source. Preserve changed or missing files for manual recovery." : "Roll back uncommitted output copies only when their hashes and the original source verify. Preserve uncertain or partially indexed files.",
                            affectedPaths: [journal.source] + journal.parts.map(\.destination), operationID: journal.id))
                    } catch { problem(folder, error) }
                }
            } catch { problem(recoveryRoot, error) }
        }
        do {
            for repair in try FinishingIssues(folder: settings.basePath).load() {
                let matches = active.filter { $0.documentID == repair.documentID && fm.fileExists(atPath: $0.path) && FileOrganizer.isInside(URL(fileURLWithPath: $0.path), settings.outboxFolder) }
                let entry = matches.count == 1 ? matches.first : nil
                report.issues.append(.init(kind: .finishing, path: entry?.path ?? repair.path, title: "Finishing steps need attention",
                    detail: repair.failures.map { "\($0.step.title): \($0.detail)" }.joined(separator: "\n") +
                        (entry == nil ? "\nRestore its Library record/PDF to enable Activity retry." : "\nOpen Activity → Review Repairs to retry enabled steps."), entry: entry))
            }
        } catch { problem(settings.basePath.appendingPathComponent(FinishingIssues.fileName), error) }
        do { _ = try ReceiptDecisions(folder: settings.basePath).snapshot() }
        catch { problem(settings.basePath.appendingPathComponent(ReceiptDecisions.fileName), error) }
        return report
    }

    public static func repair(_ issue: Issue, settings: HomeClerkSettings, index: DocumentIndex,
                              duplicates: DuplicateDetector? = nil) throws -> Result {
        guard issue.preview != nil else { throw Changed() }
        let lease = try DocumentOperations.acquire(issue.affectedPaths.map { URL(fileURLWithPath: $0) })
        defer { lease.release() }
        guard scan(settings: settings, index: index).issues.contains(issue) else { throw Changed() }
        // Pending recovery owns the file/index relationship; repair it before adding/hiding records.
        let pending = settings.basePath.appendingPathComponent(".homeclerk-operations")
        if issue.kind != .pendingOperation, FileManager.default.fileExists(atPath: pending.path),
           !(try FileManager.default.contentsOfDirectory(atPath: pending.path)).filter({ !$0.hasPrefix(".") }).isEmpty {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Recover interrupted filings before repairing Library metadata."])
        }
        switch issue.kind {
        case .unindexed:
            let file = URL(fileURLWithPath: issue.path)
            guard let pdf = PDFDocument(url: file), !pdf.isLocked, pdf.pageCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
            var entry = issue.entry ?? DocumentIndex.Entry(path: issue.path, source: file.lastPathComponent,
                pages: [1, pdf.pageCount], model: "Library Health", confidence: 0, summary: "Imported without analysis; details need review.", facets: DocumentFacets())
            entry.removed = false
            try index.append(entry)
            return Result(undo: MetadataUndo(before: issue.entry, after: entry))
        case .missing:
            guard var entry = issue.entry else { throw Changed() }
            entry.removed = true
            try index.append(entry)
            return Result(undo: MetadataUndo(before: issue.entry, after: entry))
        case .staleDuplicate:
            guard let label = issue.label else { throw Changed() }
            try FileOrganizer.requireInside(settings.duplicatesFolder, settings.basePath)
            let detector: DuplicateDetector
            if let duplicates { detector = duplicates }
            else {
                try PrivateFolder.secure(settings.duplicatesFolder)
                detector = DuplicateDetector(duplicatesFolder: settings.duplicatesFolder)
            }
            try detector.removeStaleLabel(label, organized: settings.outboxFolder)
            return Result()
        case .pendingOperation:
            guard let id = issue.operationID else { throw Changed() }
            _ = try index.loadValidated()
            _ = try FilingTransaction(settings: settings, index: index).recover(only: id)
            return Result(recovered: true)
        default: throw Changed()
        }
    }

    public static func undo(_ repair: MetadataUndo, settings: HomeClerkSettings, index: DocumentIndex) throws {
        let file = URL(fileURLWithPath: repair.after.path)
        let lease = try DocumentOperations.acquire([file]); defer { lease.release() }
        try FileOrganizer.requireInside(index.url, settings.basePath)
        try FileOrganizer.requireInside(file, settings.outboxFolder)
        var expected = repair.after
        let current = latest(try index.loadValidated())[key(file.path)]
        expected.filedAt = current?.filedAt ?? expected.filedAt
        guard current == expected else { throw Changed() }
        var before = repair.before ?? repair.after
        if repair.before == nil { before.removed = true }
        try index.append(before)
    }
}
