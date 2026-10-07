import Foundation
import Testing
@testable import HomeClerkKit

/// The HomeClerk folder can move: the Library stores paths relative to it.
@Suite struct MovableFolderTests {
    let temp = TempFolder()

    func entry(_ path: String) -> DocumentIndex.Entry {
        DocumentIndex.Entry(path: path, source: "scan.pdf", pages: [1], model: "test", confidence: 1, summary: "",
                            facets: DocumentFacets(documentType: "Receipt"))
    }

    @Test func pathsInsideTheFolderAreStoredRelativeAndReadBackInFull() throws {
        let folder = temp.url.appendingPathComponent("HomeClerk")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let index = DocumentIndex(url: folder.appendingPathComponent(DocumentIndex.fileName))
        let inside = folder.appendingPathComponent("Organized/Receipts/r.pdf").path
        try index.append([entry(inside), entry("/Volumes/Elsewhere/notes.pdf")])
        let text = try String(contentsOf: index.url, encoding: .utf8)
        #expect(text.contains("\"path\":\"Organized/Receipts/r.pdf\""))
        #expect(!text.contains(folder.path))
        #expect(index.load().map(\.path) == [inside, "/Volumes/Elsewhere/notes.pdf"])
    }

    @Test func aMovedFolderStillFindsItsDocuments() throws {
        let old = temp.url.appendingPathComponent("DocuSort"), new = temp.url.appendingPathComponent("HomeClerk")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        // Written by an older version: full paths at the old location
        let legacy = try JSONEncoder().encode(entry(old.appendingPathComponent("Organized/Bills/b.pdf").path))
        try (String(decoding: legacy, as: UTF8.self) + "\n").write(to: old.appendingPathComponent(DocumentIndex.fileName),
                                                                   atomically: true, encoding: .utf8)
        try DocumentIndex(url: old.appendingPathComponent(DocumentIndex.fileName))
            .append(entry(old.appendingPathComponent("_review/s.pdf").path))

        try FileManager.default.moveItem(at: old, to: new)
        let moved = DocumentIndex(url: new.appendingPathComponent(DocumentIndex.fileName))
        #expect(moved.load().map(\.path) == [new.appendingPathComponent("Organized/Bills/b.pdf").path,
                                             new.appendingPathComponent("_review/s.pdf").path])
        #expect(try moved.loadValidated().map(\.path) == moved.load().map(\.path))
    }

    func makeFolder(_ name: String) throws -> URL {
        let folder = temp.url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Organized/Receipts"), withIntermediateDirectories: true)
        try Data("receipt".utf8).write(to: folder.appendingPathComponent("Organized/Receipts/r.pdf"))
        try Data("{}\n".utf8).write(to: folder.appendingPathComponent(DocumentIndex.fileName))
        return folder
    }

    @Test func movesRefuseWhatCantWork() throws {
        let folder = try makeFolder("DocuSort")
        let taken = temp.url.appendingPathComponent("Taken")
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
        #expect(throws: FolderMove.Problem.self) { try FolderMove.check(from: folder, to: folder) }
        #expect(throws: FolderMove.Problem.self) { try FolderMove.check(from: folder, to: folder.appendingPathComponent("Inside")) }
        #expect(throws: FolderMove.Problem.self) { try FolderMove.check(from: folder, to: taken) }
        #expect(throws: FolderMove.Problem.self) { try FolderMove.check(from: folder, to: temp.url.appendingPathComponent("No/Such/Place")) }
        #expect(throws: FolderMove.Problem.self) { try FolderMove.check(from: temp.url.appendingPathComponent("Gone"), to: taken) }
        try FolderMove.check(from: folder, to: temp.url.appendingPathComponent("HomeClerk"))
    }

    @Test func aMoveOnOneDriveRenamesAndOneAcrossDrivesCopiesThenRetires() throws {
        let renamed = temp.url.appendingPathComponent("HomeClerk")
        try FolderMove.move(from: try makeFolder("DocuSort"), to: renamed)
        #expect(FolderMove.looksLikeHomeClerkFolder(renamed))
        #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("DocuSort").path))

        let source = try makeFolder("Local"), copy = temp.url.appendingPathComponent("External")
        var retired: URL?
        try FolderMove.move(from: source, to: copy, copying: true) { retired = $0 }
        #expect(retired == source)
        #expect(FolderMove.inventory(copy) == ["Organized/Receipts/r.pdf": 7, "index.jsonl": 3])
    }

    @Test func pathsInTheFolderFollowIt() {
        let old = URL(fileURLWithPath: "/Users/pat/DocuSort"), new = URL(fileURLWithPath: "/Users/pat/HomeClerk")
        #expect(FolderMove.rebased("/Users/pat/DocuSort/Organized/a.pdf", from: old, to: new) == "/Users/pat/HomeClerk/Organized/a.pdf")
        #expect(FolderMove.rebased("/Users/pat/DocuSortOther/a.pdf", from: old, to: new) == nil)
        #expect(FolderMove.looksLikeHomeClerkFolder(URL(fileURLWithPath: "/usr")) == false)
    }
}
