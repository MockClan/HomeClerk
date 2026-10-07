import Foundation
import Testing
@testable import HomeClerkKit

@Suite struct PrivateFileTests {
    let temp = TempFolder()

    func mode(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    @Test func writesAreOwnerOnlyEvenOverAnOpenFile() throws {
        let url = temp.url.appendingPathComponent("sub/notes.json")
        try PrivateFile.writeJSON(["a": 1], to: url)
        #expect(try mode(url) == 0o600)
        #expect(PrivateFile.readJSON([String: Int].self, from: url) == ["a": 1])

        // An older file anyone could read is replaced by a private one
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try PrivateFile.write(Data("{}".utf8), to: url)
        #expect(try mode(url) == 0o600)
        // No temporary files left behind
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["notes.json"])
    }

    @Test func appendCreatesAPrivateFileThenAdds() throws {
        let url = temp.url.appendingPathComponent("log.jsonl")
        try PrivateFile.append(Data("one\n".utf8), to: url)
        try PrivateFile.append(Data("two\n".utf8), to: url)
        #expect(try mode(url) == 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8) == "one\ntwo\n")
    }
}
