import Foundation
import Testing
@testable import HomeClerkKit

@Suite struct MailRuleTests {
    let temp = TempFolder()

    @Test func theScriptSavesIntoTheInboxWithAQuotedPath() {
        let source = MailRule.source(inbox: URL(fileURLWithPath: "/Users/jane/Docs \"Home\"/Inbox"))
        #expect(source.contains(#"set inboxFolder to "/Users/jane/Docs \"Home\"/Inbox/""#))
        #expect(source.contains("on perform mail action with messages"))
    }

    @Test func compilesIntoTheScriptsFolder() throws {
        let folder = temp.url.appendingPathComponent("com.apple.mail")
        let script = try MailRule.install(inbox: temp.url.appendingPathComponent("Inbox"), in: folder)
        #expect(MailRule.isInstalled(in: folder))
        let decompiler = Process()
        decompiler.executableURL = URL(fileURLWithPath: "/usr/bin/osadecompile")
        decompiler.arguments = [script.path]
        let output = Pipe()
        decompiler.standardOutput = output
        try decompiler.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        decompiler.waitUntilExit()
        #expect(text.contains(temp.url.appendingPathComponent("Inbox").path + "/"))
    }
}
