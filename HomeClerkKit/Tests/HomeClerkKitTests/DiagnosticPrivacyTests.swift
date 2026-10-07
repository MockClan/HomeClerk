import Foundation
import Testing
@testable import HomeClerkKit

struct DiagnosticPrivacyTests {
    @Test func customSettingsDoNotExportPersonalTextOrCredentials() throws {
        let secret = "Alice-private-invoice-sk-ant-secret"
        var settings = HomeClerkSettings(basePath: URL(fileURLWithPath: "/Users/\(secret)/Invoices.pdf"))
        settings.claudeModel = secret
        settings.ollamaModel = secret
        settings.appleModel = secret
        settings.remindersList = secret
        settings.ollamaBaseURL = try #require(URL(string: "https://\(secret):password@\(secret).example:8443/\(secret)?token=\(secret)#\(secret)"))
        let report = settings.diagnosticValues.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        for privateValue in [secret, "password", "Invoices.pdf", "/Users/", ".example", "token="] {
            #expect(!report.contains(privateValue))
        }
        #expect(report.contains("https, remote host, port 8443"))
        #expect(report.contains("AiProvider: Claude"))
        #expect(report.contains("MakeSearchable: true"))
        // Exporting must not alter the settings used for filing or network requests.
        #expect(settings.remindersList == secret)
        #expect(settings.ollamaBaseURL.absoluteString.contains(secret))
    }

    @Test(arguments: [
        ("http://user:secret@localhost:11434/private?key=secret#secret", "http, loopback, port 11434 (URL omitted)"),
        ("http://[::1]:11434/private", "http, loopback, port 11434 (URL omitted)"),
        ("https://127.0.0.1/private", "https, loopback (URL omitted)"),
        ("https://localhost.private.example/private", "https, remote host (URL omitted)"),
        ("file:///Users/Alice/Invoice.pdf", "custom endpoint (URL omitted)"),
        ("secret://Alice/private?password=secret", "custom endpoint (URL omitted)"),
        ("/Users/Alice/private", "custom endpoint (URL omitted)")
    ]) func endpointSummariesWithholdArbitraryURLComponents(input: String, expected: String) throws {
        #expect(DiagnosticPrivacy.endpoint(try #require(URL(string: input))) == expected)
    }

    @Test func defaultSettingsRemainUsefulWithoutExportingHomePath() {
        let values = Dictionary(uniqueKeysWithValues: HomeClerkSettings().diagnosticValues.map { ($0.key, $0.value) })
        #expect(values["BasePath"] == "default folder")
        #expect(values["RemindersList"] == "default list")
        #expect(values["ClaudeModel"] == HomeClerkSettings().claudeModel)
        #expect(values["OllamaBaseUrl"] == "http, loopback, port 11434 (URL omitted)")
    }

    @Test func unknownLogCategoriesCannotSmugglePrivateText() {
        #expect(DiagnosticPrivacy.logCategory("claude") == "claude")
        #expect(DiagnosticPrivacy.logCategory("Alice Invoice.pdf sk-ant-secret") == "other")
        #expect(DiagnosticPrivacy.logCategory("claude\nAuthorization: secret") == "other")
    }
}
