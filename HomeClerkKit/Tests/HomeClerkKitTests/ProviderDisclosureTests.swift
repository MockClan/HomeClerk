import Foundation
import Testing
@testable import HomeClerkKit

struct ProviderDisclosureTests {
    @Test func localPrimaryWithCloudFallbackDisclosesBoth() {
        var settings = HomeClerkSettings()
        settings.aiProvider = .ollama
        settings.fallbackProvider = .claude
        #expect(settings.analysisPrivacySummary.contains("on this Mac"))
        #expect(settings.analysisPrivacySummary.contains("Fallback: Claude"))
        #expect(settings.analysisPrivacySummary.contains("Anthropic's cloud API"))
        #expect(settings.analysisPrivacySummary.contains("automatically"))
    }

    @Test(arguments: ["http://localhost:11434", "http://127.0.0.1:11434", "http://[::1]:11434"])
    func loopbackDisclosesServerForwardingWithoutRemoteHTTPWarning(address: String) throws {
        var settings = HomeClerkSettings()
        settings.ollamaBaseURL = try #require(URL(string: address))
        #expect(settings.ollamaUsesLoopback)
        #expect(settings.ollamaTransportWarning == nil)
        #expect(settings.analysisDestination(for: .ollama).contains("cloud models or forwarding"))
    }

    @Test(arguments: ["http://localhost.example:11434", "http://192.168.1.10:11434", "http://127.0.0.1.example"])
    func remoteHTTPWarnsEvenForMisleadingHostnames(address: String) throws {
        var settings = HomeClerkSettings()
        settings.ollamaBaseURL = try #require(URL(string: address))
        #expect(!settings.ollamaUsesLoopback)
        #expect(settings.ollamaTransportWarning?.contains("without transport encryption") == true)
        #expect(settings.analysisDestination(for: .ollama).contains("remote server"))
    }

    @Test func remoteHTTPSDisclosesDestinationWithoutCredentials() throws {
        var settings = HomeClerkSettings()
        settings.ollamaBaseURL = try #require(URL(string: "https://alice:secret@reader.example:8443/private?token=secret#secret"))
        let text = settings.analysisDestination(for: .ollama)
        #expect(text.contains("https://reader.example:8443"))
        for omitted in ["alice", "secret", "private", "token"] { #expect(!text.contains(omitted)) }
        #expect(settings.ollamaTransportWarning == nil)
    }

    @Test func appleCloudAndNoFallbackAreExplicit() {
        var settings = HomeClerkSettings()
        settings.aiProvider = .apple
        settings.fallbackProvider = nil
        #expect(settings.analysisPrivacySummary.contains("on-device"))
        #expect(settings.analysisPrivacySummary.contains("goes to Review"))
        settings.appleModel = "private-cloud"
        #expect(settings.analysisPrivacySummary.contains("may leave this Mac"))
        settings.fallbackProvider = .apple
        #expect(!settings.analysisPrivacySummary.contains("Fallback:"))
    }

    @Test func invalidEndpointCannotBeDescribedAsLocal() throws {
        var settings = HomeClerkSettings()
        settings.ollamaBaseURL = try #require(URL(string: "file:///Users/Alice/secret"))
        #expect(settings.analysisDestination(for: .ollama).contains("invalid server address"))
        #expect(!settings.analysisDestination(for: .ollama).contains("Alice"))
    }
}
