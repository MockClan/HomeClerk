import Foundation
import Testing
@testable import HomeClerkKit

@Suite struct BackfillUndoSafetyTests {
    let temp = TempFolder()
    var organized: URL { temp.url.appendingPathComponent("Organized") }
    var log: URL { temp.url.appendingPathComponent("undo.json") }

    func file(_ path: String, text: String = "Fictional PDF bytes") throws -> URL {
        let url = temp.url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PrivateFile.write(Data(text.utf8), to: url)
        return url
    }
    func move(_ from: URL, _ to: URL) throws -> BackfillApplier.UndoMove {
        .init(from: from.path, to: to.path, sha256: BackfillApplier.sha256(try Data(contentsOf: from)))
    }
    func save(_ moves: [BackfillApplier.UndoMove]) throws { try PrivateFile.writeJSON(moves, to: log) }

    @Test func validLogRestoresPDFAndNeverOverwritesAConflict() throws {
        let source = try file("Organized/New/a.pdf")
        let to = organized.appendingPathComponent("Old/a.pdf")
        try save([move(source, to)])
        let result = try BackfillApplier.undo(log, organized: organized)
        #expect(result.restored == 1 && result.problems.isEmpty)
        #expect(try Data(contentsOf: to) == Data("Fictional PDF bytes".utf8))
        let repeated = try BackfillApplier.undo(log, organized: organized)
        #expect(repeated.restored == 0 && repeated.problems.count == 1)

        let next = try file("Organized/New/b.pdf", text: "Original")
        let occupied = try file("Organized/Old/b.pdf", text: "Other document")
        try save([move(next, occupied)])
        let conflict = try BackfillApplier.undo(log, organized: organized)
        #expect(conflict.restored == 0 && conflict.problems.count == 1)
        #expect(try String(contentsOf: next, encoding: .utf8) == "Original")
        #expect(try String(contentsOf: occupied, encoding: .utf8) == "Other document")
    }

    @Test(arguments: ["source", "destination", "traversal", "prefix", "relative", "non_pdf"])
    func unsafeLogIsRejectedBeforeAnyValidMove(kind: String) throws {
        let safe = try file("Organized/New/valid.pdf")
        let safeDestination = organized.appendingPathComponent("Old/valid.pdf")
        let external = try file("Outside/private.pdf", text: "Unrelated private document")
        var invalid = try move(safe, organized.appendingPathComponent("Other/invalid.pdf"))
        switch kind {
        case "source": invalid.from = external.path
        case "destination": invalid.to = temp.url.appendingPathComponent("Outside/created/invalid.pdf").path
        case "traversal": invalid.to = organized.path + "/../Outside/invalid.pdf"
        case "prefix": invalid.to = temp.url.appendingPathComponent("OrganizedOther/invalid.pdf").path
        case "relative": invalid.to = "Old/invalid.pdf"
        default: invalid.to = organized.appendingPathComponent("other.txt").path
        }
        // Reverse execution would perform the valid move first without whole-log validation.
        try save([invalid, move(safe, safeDestination)])
        #expect(throws: BackfillApplier.InvalidUndoLog.self) { try BackfillApplier.undo(log, organized: organized) }
        #expect(FileManager.default.fileExists(atPath: safe.path))
        #expect(!FileManager.default.fileExists(atPath: safeDestination.deletingLastPathComponent().path))
        #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("Outside/created").path))
        #expect(try String(contentsOf: external, encoding: .utf8) == "Unrelated private document")
    }

    @Test(arguments: ["source_file", "source_folder", "destination_folder", "dangling_destination", "internal_destination"])
    func symlinkPathsAreRejected(kind: String) throws {
        let source = try file("Organized/New/file.pdf")
        let external = try file("Outside/private.pdf", text: "Leave alone")
        var entry = try move(source, organized.appendingPathComponent("Old/file.pdf"))
        switch kind {
        case "source_file":
            let link = organized.appendingPathComponent("linked.pdf")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
            entry.from = link.path
        case "source_folder":
            let link = organized.appendingPathComponent("Linked")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external.deletingLastPathComponent())
            entry.from = link.appendingPathComponent("private.pdf").path
        default:
            let link = organized.appendingPathComponent("Linked")
            let target = kind == "internal_destination" ? source.deletingLastPathComponent()
                : kind == "dangling_destination" ? temp.url.appendingPathComponent("Missing") : external.deletingLastPathComponent()
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            entry.to = link.appendingPathComponent("restored.pdf").path
        }
        try save([entry])
        #expect(throws: BackfillApplier.InvalidUndoLog.self) { try BackfillApplier.undo(log, organized: organized) }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try String(contentsOf: external, encoding: .utf8) == "Leave alone")
        #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("Outside/restored.pdf").path))
    }

    @Test(arguments: ["{}", "null", "[null]", "[{\"from\":123,\"to\":false}]", "[{\"from\":\"/x.pdf\",\"to\":\"/y.pdf\"}]"])
    func malformedAndLegacyLogsFailClearly(json: String) throws {
        let source = try file("Organized/file.pdf")
        try PrivateFile.write(Data(json.utf8), to: log)
        #expect(throws: BackfillApplier.InvalidUndoLog.self) { try BackfillApplier.undo(log, organized: organized) }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func invalidHashOrDuplicateMoveRefusesWholeLog() throws {
        let source = try file("Organized/file.pdf")
        let destination = organized.appendingPathComponent("Old/file.pdf")
        var invalid = try move(source, destination)
        invalid.sha256 = "not a hash"
        try save([invalid])
        #expect(throws: BackfillApplier.InvalidUndoLog.self) { try BackfillApplier.undo(log, organized: organized) }
        let valid = try move(source, destination)
        try save([valid, valid])
        #expect(throws: BackfillApplier.InvalidUndoLog.self) { try BackfillApplier.undo(log, organized: organized) }
        try save([move(source, source)])
        #expect(throws: BackfillApplier.InvalidUndoLog.self) { try BackfillApplier.undo(log, organized: organized) }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func changedPDFIsPreservedWhileUnchangedPDFIsRestored() throws {
        let changed = try file("Organized/New/changed.pdf")
        let safe = try file("Organized/New/safe.pdf")
        let safeTo = organized.appendingPathComponent("Old/safe.pdf")
        try save([move(changed, organized.appendingPathComponent("Old/changed.pdf")), move(safe, safeTo)])
        try PrivateFile.write(Data("New replacement".utf8), to: changed)
        let result = try BackfillApplier.undo(log, organized: organized)
        #expect(result.restored == 1 && result.problems.count == 1)
        #expect(result.problems[0].contains("changed since backfill"))
        #expect(try String(contentsOf: changed, encoding: .utf8) == "New replacement")
        #expect(FileManager.default.fileExists(atPath: safeTo.path))
    }

    @Test func directoryNamedPDFIsNeverMoved() throws {
        let source = try file("Organized/folder.pdf/child.txt")
        let folder = source.deletingLastPathComponent()
        let entry = BackfillApplier.UndoMove(from: folder.path, to: organized.appendingPathComponent("old.pdf").path,
                                            sha256: String(repeating: "0", count: 64))
        try save([entry])
        let result = try BackfillApplier.undo(log, organized: organized)
        #expect(result.restored == 0 && result.problems.count == 1)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func dependentMovesStillRestoreInReverseOrder() throws {
        let first = try file("Organized/new.pdf", text: "First document")
        let second = try file("Organized/original.pdf", text: "Second document")
        let secondOriginal = organized.appendingPathComponent("second.pdf")
        // The first move freed original.pdf, which the second move then used.
        try save([move(first, second), move(second, secondOriginal)])
        let result = try BackfillApplier.undo(log, organized: organized)
        #expect(result.restored == 2 && result.problems.isEmpty)
        #expect(try String(contentsOf: second, encoding: .utf8) == "First document")
        #expect(try String(contentsOf: secondOriginal, encoding: .utf8) == "Second document")
    }
}
