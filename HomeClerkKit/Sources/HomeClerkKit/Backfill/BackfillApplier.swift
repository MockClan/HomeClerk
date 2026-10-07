import CryptoKit
import Foundation

/// Carries out a reviewed backfill plan: moves or renames the entries marked apply, runs the
/// finishing steps, records them in the index, and writes an undo log of every move.
public struct BackfillApplier: Sendable {
    let finisher: Finisher
    let index: DocumentIndex
    let duplicates: DuplicateDetector

    public init(finisher: Finisher, index: DocumentIndex, duplicates: DuplicateDetector) {
        self.finisher = finisher
        self.index = index
        self.duplicates = duplicates
    }

    /// Hashes describe the finished PDFs, since adding searchable text changes their bytes.
    struct UndoMove: Codable {
        var from: String
        var to: String
        var sha256: String
        var before: DocumentIndex.Entry? = nil
        var after: DocumentIndex.Entry? = nil
        var duplicateBefore: DuplicateDetector.Snapshot? = nil
        var status: Status? = nil
        var undoOperationID: String? = nil
        enum Status: String, Codable { case prepared, applied, restored, undone }
    }

    struct InvalidUndoLog: LocalizedError {
        let reason: String
        var errorDescription: String? { "Backfill undo refused: \(reason). No files were moved." }
    }

    public struct Result: Sendable {
        public var moved = 0, renamed = 0, finished = 0
        public var problems: [String] = []
        public var undoLog: URL
    }

    public func apply(_ plan: BackfillPlan, undoFolder: URL) async throws -> Result {
        let organized = URL(fileURLWithPath: plan.organizedFolder)
        let organizer = FileOrganizer(outbox: organized)
        var undo: [UndoMove] = []
        var result = Result(undoLog: undoFolder)
        try PrivateFolder.secure(undoFolder)
        result.undoLog = undoFolder.appendingPathComponent("backfill-undo-\(UUID().uuidString).json")
        // Fail before any document changes if the log cannot be created.
        try PrivateFile.writeJSON(undo, to: result.undoLog)
        let marks = PaidMarks(url: index.url.deletingLastPathComponent().appendingPathComponent(PaidMarks.fileName))

        for entry in plan.entries where entry.apply && entry.action != .skip {
            guard let facets = entry.facets else { continue }
            let current = organized.appendingPathComponent(entry.path)
            // Plans are JSON a person can edit; a path must stay inside Organized
            guard FileOrganizer.isInside(current, organized) else {
                result.problems.append("\(entry.path): outside the Organized folder — skipped")
                continue
            }
            guard let data = try? Data(contentsOf: current) else {
                result.problems.append("\(entry.path): no longer there — skipped")
                continue
            }
            guard Self.sha256(data) == entry.sha256 else {
                result.problems.append("\(entry.path): changed since the plan was made — skipped")
                continue
            }
            do {
                let old = index.load().last { URL(fileURLWithPath: $0.path).standardizedFileURL == current.standardizedFileURL }
                    .flatMap { $0.removed ? nil : $0 }
                if let old { try marks.migrateLegacyMark(for: old) }
                var destination = current
                if entry.action == .move || entry.action == .rename {
                    destination = try organizer.destination(folder: entry.proposedFolder, filename: entry.proposedName)
                }
                let settings = HomeClerkSettings(values: ["basepath": .string(organized.deletingLastPathComponent().path)])
                guard settings.outboxFolder.standardizedFileURL == organized.standardizedFileURL else {
                    throw FilingTransaction.Failure("Backfill recovery requires the Organized folder inside HomeClerk")
                }
                var record = DocumentIndex.Entry(documentID: old?.documentID ?? UUID().uuidString,
                    path: destination.path, source: "backfill:\(entry.path)", pages: [], model: entry.model,
                    confidence: entry.confidence, summary: entry.summary, facets: facets)
                record.corrected = old?.corrected ?? false
                record.operationID = UUID().uuidString
                let oldLabel = Self.label(current, organized: organized)
                let newLabel = Self.label(destination, organized: organized)
                let operation = UndoMove(from: destination.path, to: current.path, sha256: entry.sha256,
                    before: old, after: record, duplicateBefore: duplicates.snapshot(label: oldLabel), status: .prepared)
                undo.append(operation)
                do { try PrivateFile.writeJSON(undo, to: result.undoLog) }
                catch {
                    undo.removeLast()
                    result.problems.append("Undo log could not be saved; remaining documents were left unchanged: \(error.localizedDescription)")
                    break
                }
                let saved = try FilingTransaction(settings: settings, index: index).execute(source: current,
                    outputs: [.init(destination: destination, entry: record)], operationID: record.operationID!)
                result.problems.append(contentsOf: saved.warnings)
                if destination != current {
                    if entry.action == .move { result.moved += 1 } else { result.renamed += 1 }
                }
                result.finished += 1
                let outcome = await finisher.finish(destination, facets: facets, today: DocumentProcessor.localToday(), documentID: record.documentID)
                result.problems.append(contentsOf: outcome.warnings)
                let finishedHash = Self.sha256(try Data(contentsOf: destination))
                undo[undo.count - 1].sha256 = finishedHash
                undo[undo.count - 1].status = .applied
                try PrivateFile.writeJSON(undo, to: result.undoLog)
                try duplicates.replace(ocrText: Finisher.text(of: destination), sha256: finishedHash,
                    facets: facets, label: newLabel, replacing: [oldLabel, newLabel])
            } catch {
                result.problems.append("\(entry.path): \(error.localizedDescription)")
            }
        }

        Self.removeEmptyFolders(organized)
        return result
    }

    /// Validates the whole log before changing anything, then restores unchanged PDFs in reverse
    /// order. Missing, changed, or occupied files are reported without overwriting documents.
    public static func undo(_ undoLog: URL, organized: URL, index suppliedIndex: DocumentIndex? = nil,
                            duplicates suppliedDuplicates: DuplicateDetector? = nil) throws -> (restored: Int, problems: [String]) {
        guard FileOrganizer.isInside(organized, organized) else {
            throw InvalidUndoLog(reason: "Organized is a symbolic link or inaccessible")
        }
        let data = try Data(contentsOf: undoLog)
        var moves: [UndoMove]
        do { moves = try JSONDecoder().decode([UndoMove].self, from: data) }
        catch {
            throw InvalidUndoLog(reason: "the log must be an array of from/to paths and SHA-256 hashes; older logs without hashes cannot be verified")
        }
        var sources = Set<String>(), destinations = Set<String>()
        for move in moves {
            guard move.sha256.count == 64, move.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw InvalidUndoLog(reason: "a file hash is invalid")
            }
            let from = URL(fileURLWithPath: move.from), to = URL(fileURLWithPath: move.to)
            guard move.from.hasPrefix("/"), move.to.hasPrefix("/"),
                  !move.from.contains("\0"), !move.to.contains("\0"),
                  from.pathExtension.lowercased() == "pdf", to.pathExtension.lowercased() == "pdf",
                  FileOrganizer.isInside(from, organized), FileOrganizer.isInside(to, organized) else {
                throw InvalidUndoLog(reason: "a PDF path is outside Organized or contains a symbolic link or traversal")
            }
            let sourceKey = from.resolvingSymlinksInPath().standardized.path
            let destinationKey = to.resolvingSymlinksInPath().standardized.path
            guard (sourceKey != destinationKey || move.after != nil), sources.insert(sourceKey).inserted,
                  destinations.insert(destinationKey).inserted else {
                throw InvalidUndoLog(reason: "a move is duplicated or points to itself")
            }
            if let after = move.after {
                guard move.status != nil, let snapshot = move.duplicateBefore,
                      after.path == move.from, UUID(uuidString: after.operationID ?? "") != nil,
                      !after.documentID.isEmpty, !after.removed,
                      move.before.map({ $0.path == move.to && $0.documentID == after.documentID && !$0.removed }) ?? true,
                      snapshot.containsOnly(label: label(to, organized: organized)),
                      move.undoOperationID.map({ UUID(uuidString: $0) != nil }) ?? true else {
                    throw InvalidUndoLog(reason: "the metadata snapshot does not match its file operation")
                }
            } else if move.before != nil || move.duplicateBefore != nil || move.status != nil || move.undoOperationID != nil {
                throw InvalidUndoLog(reason: "an operation is missing its metadata snapshot")
            }
        }
        var restored = 0
        var problems: [String] = []
        let settings = HomeClerkSettings(values: ["basepath": .string(organized.deletingLastPathComponent().path)])
        let index = suppliedIndex ?? DocumentIndex(url: settings.basePath.appendingPathComponent(DocumentIndex.fileName))
        if moves.contains(where: { $0.after != nil }) {
            guard settings.outboxFolder.resolvingSymlinksInPath() == organized.resolvingSymlinksInPath() else {
                throw InvalidUndoLog(reason: "snapshot logs require the archive's Organized folder")
            }
            try FileOrganizer.requireInside(settings.duplicatesFolder, settings.basePath)
            _ = try FilingTransaction(settings: settings, index: index).recover()
        }
        let duplicates = suppliedDuplicates ?? DuplicateDetector(duplicatesFolder: settings.duplicatesFolder)
        for i in moves.indices.reversed() {
            let move = moves[i]
            if move.after != nil {
                do {
                    let count = try undoOperation(i, moves: &moves, log: undoLog, settings: settings,
                        organized: organized, index: index, duplicates: duplicates, problems: &problems)
                    restored += count
                } catch { problems.append("\(move.from): \(error.localizedDescription)") }
                continue
            }
            let from = URL(fileURLWithPath: move.from), to = URL(fileURLWithPath: move.to)
            do {
                // Recheck immediately before the mutation; the log may outlive directory changes.
                try FileOrganizer.requireInside(from, organized)
                try FileOrganizer.requireInside(to, organized)
                guard FileManager.default.fileExists(atPath: from.path) else {
                    problems.append("\(move.from): not found"); continue
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: from.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      sha256(try Data(contentsOf: from)) == move.sha256 else {
                    problems.append("\(move.from): changed since backfill — preserved"); continue
                }
                guard !FileManager.default.fileExists(atPath: to.path) else {
                    problems.append("\(move.to): something is already there — preserved"); continue
                }
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileOrganizer.requireInside(from, organized)
                try FileOrganizer.requireInside(to, organized)
                try FileManager.default.moveItem(at: from, to: to)
                restored += 1
            } catch { problems.append("\(move.from): \(error.localizedDescription)") }
        }
        if restored > 0 { removeEmptyFolders(organized) }
        return (restored, problems)
    }

    /// A persisted undo ID lets retries distinguish our own restoration from later user edits.
    private static func undoOperation(_ i: Int, moves: inout [UndoMove], log: URL, settings: HomeClerkSettings,
                                      organized: URL, index: DocumentIndex, duplicates: DuplicateDetector,
                                      problems: inout [String]) throws -> Int {
        let move = moves[i]
        guard move.status != .undone else { return 0 }
        let after = move.after!
        let from = URL(fileURLWithPath: move.from), to = URL(fileURLWithPath: move.to)
        try FileOrganizer.requireInside(index.url, settings.basePath)
        if FileManager.default.fileExists(atPath: index.url.path) { _ = try Data(contentsOf: index.url) }
        let entries = index.load()
        var before = move.before ?? after
        if move.before == nil { before.removed = true }
        before.path = to.path
        var alreadyRestored = false
        if let undoID = move.undoOperationID {
            before.operationID = undoID
            alreadyRestored = entries.last(where: { $0.path == to.path }) == before
        }
        if !alreadyRestored {
            guard entries.last(where: { $0.path == from.path }) == after else {
                // Prepared records whose transaction never committed are safe no-ops.
                if move.status == .prepared, !entries.contains(where: { $0.operationID == after.operationID }) {
                    moves[i].status = .undone
                    try PrivateFile.writeJSON(moves, to: log)
                    return 0
                }
                throw FilingTransaction.Failure("Metadata changed since backfill; document preserved")
            }
        }
        let current = alreadyRestored ? to : from
        try FileOrganizer.requireInside(current, organized)
        try FileOrganizer.requireInside(to, organized)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              sha256(try Data(contentsOf: current)) == move.sha256 else {
            throw FilingTransaction.Failure("File missing or changed since backfill; document preserved")
        }
        if !alreadyRestored {
            guard from.standardizedFileURL == to.standardizedFileURL || !FileManager.default.fileExists(atPath: to.path) else {
                throw FilingTransaction.Failure("Original destination is occupied; both documents preserved")
            }
            let undoID = move.undoOperationID ?? UUID().uuidString
            moves[i].undoOperationID = undoID
            // Persist our intent before the transaction can change either files or metadata.
            try PrivateFile.writeJSON(moves, to: log)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            let saved = try FilingTransaction(settings: settings, index: index).execute(source: from,
                outputs: [.init(destination: to, entry: before)], operationID: undoID)
            problems.append(contentsOf: saved.warnings)
            moves[i].status = .restored
            do { try PrivateFile.writeJSON(moves, to: log) }
            catch {
                problems.append("File and metadata restored; saving undo progress needs retry: \(error.localizedDescription)")
                return 1
            }
        }
        do {
            try duplicates.restore(move.duplicateBefore!, replacing: [label(from, organized: organized), label(to, organized: organized)])
        } catch {
            problems.append("File and metadata restored; duplicate records need retry: \(error.localizedDescription)")
            return alreadyRestored ? 0 : 1
        }
        moves[i].status = .undone
        do { try PrivateFile.writeJSON(moves, to: log) }
        catch { problems.append("Restoration completed; saving undo progress needs retry: \(error.localizedDescription)") }
        return alreadyRestored ? 0 : 1
    }

    private static func label(_ url: URL, organized: URL) -> String {
        FileOrganizer.relativePath(url, in: organized) ?? url.lastPathComponent
    }

    /// Rebuilds the duplicate index from index.jsonl and each filed PDF's text layer.
    public static func rebuildDuplicateIndex(_ index: DocumentIndex, duplicates: DuplicateDetector, organized: URL)
        throws -> (documents: Int, withText: Int) {
        let base = organized.standardizedFileURL.path + "/"
        let documents = try DocumentLibrary.load(index).documents.filter { FileOrganizer.isInside(URL(fileURLWithPath: $0.path), organized) }.map { entry in
            let url = URL(fileURLWithPath: entry.path)
            let path = url.standardizedFileURL.path
            return (ocrText: Finisher.text(of: url), sha256: sha256(try Data(contentsOf: url)), facets: entry.facets,
                    label: path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent)
        }
        duplicates.rebuild(documents)
        return (documents.count, documents.filter { $0.ocrText.utf16.count >= DuplicateDetector.minTextLength }.count)
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Removes folders left empty (a .DS_Store alone counts as empty), deepest first.
    static func removeEmptyFolders(_ root: URL) {
        let folders = (FileManager.default.subpaths(atPath: root.path) ?? [])
            .map { root.appendingPathComponent($0) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.path.count > $1.path.count }
        for folder in folders where FileOrganizer.isInside(folder, root) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            if contents.allSatisfy({ $0 == ".DS_Store" }) { try? FileManager.default.removeItem(at: folder) }
        }
    }
}
