import Foundation
import Testing
@testable import HomeClerkKit

struct ReaderPolicyTests {
    @Test func enablingPolicyBlocksAnAlreadyConstructedRemoteReaderAtDispatch() async throws {
        var settings = HomeClerkSettings()
        settings.ollamaBaseURL = try #require(URL(string: "http://remote.example"))
        let enabled = Locked(false)
        let analyzer = HomeClerkPipeline.analyzer(.ollama, settings: settings, taxonomy: TestData.taxonomy,
            profile: .empty, ledger: nil, localOnlyPolicy: { enabled.value })
        enabled.mutate { $0 = true }
        let result = await analyzer.analyze(ocrText: "PRIVATE", pageCount: 1, pdf: URL(fileURLWithPath: "/nonexistent.pdf"))
        #expect(result.error?.contains("Local readers only") == true)
    }

    @Test func cancelledPrimaryNeverStartsFallback() async {
        struct Cancelling: FacetAnalyzer {
            let modelName = "primary"
            let isPaid = false
            func analyze(ocrText: String, pageCount: Int, pdf: URL) async -> FacetAnalysis {
                withUnsafeCurrentTask { $0?.cancel() }
                return .failed("Cancelled", transient: true)
            }
        }
        let fallback = FakeAnalyzer("cloud")
        let task = Task {
            await ResilientFacetAnalyzer(primary: Cancelling(), fallback: fallback, delay: { _ in })
                .analyze(ocrText: "PRIVATE", pageCount: 1, pdf: URL(fileURLWithPath: "/unused.pdf"))
        }
        let result = await task.value
        #expect(result.error == "Cancelled")
        #expect(fallback.calls == 0)
    }
    @Test func defaultsPreserveExistingReaderChoices() {
        let settings = HomeClerkSettings()
        #expect(!settings.localReadersOnly)
        for provider in AIProvider.allCases { #expect(settings.readerPolicyProblem(for: provider) == nil) }
    }

    @Test func policyPersistsAndEnvironmentCanEnableIt() {
        let name = "ReaderPolicyTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        var settings = HomeClerkSettings()
        settings.localReadersOnly = true
        store.save(settings)
        #expect(store.load(environment: [:]).localReadersOnly)
        settings.localReadersOnly = false
        store.save(settings)
        #expect(!store.load(environment: [:]).localReadersOnly)
        #expect(store.load(environment: ["HOMECLERK_HomeClerk__LocalReadersOnly": "true"]).localReadersOnly)
    }

    @Test(arguments: ["http://reader.example", "http://localhost.example", "http://192.168.1.5", "file:///localhost/private"])
    func factoryRefusesDisallowedOllamaBeforeReadingPDFOrSendingData(address: String) async throws {
        var settings = HomeClerkSettings()
        settings.localReadersOnly = true
        settings.ollamaBaseURL = try #require(URL(string: address))
        let analyzer = HomeClerkPipeline.analyzer(.ollama, settings: settings, taxonomy: TestData.taxonomy,
                                                profile: .empty, ledger: nil)
        let result = await analyzer.analyze(ocrText: "PRIVATE DOCUMENT", pageCount: 1, pdf: URL(fileURLWithPath: "/nonexistent.pdf"))
        #expect(result.error?.contains("Local readers only") == true)
        #expect(OllamaMonitor.role(for: settings) == nil)
    }

    @Test func cloudFactoriesAreBlockedAndLocalReadersRemainAvailable() async {
        var settings = HomeClerkSettings()
        settings.localReadersOnly = true
        settings.appleModel = "private-cloud"
        for provider in [AIProvider.claude, .apple] {
            let analyzer = HomeClerkPipeline.analyzer(provider, settings: settings, taxonomy: TestData.taxonomy,
                                                    profile: .empty, ledger: nil)
            let result = await analyzer.analyze(ocrText: "PRIVATE", pageCount: 1, pdf: URL(fileURLWithPath: "/nonexistent.pdf"))
            #expect(result.error?.contains("Local readers only") == true)
        }
        settings.appleModel = "on-device"
        #expect(settings.readerPolicyProblem(for: .apple) == nil)
        #expect(settings.readerPolicyProblem(for: .ollama) == nil)
        #expect(settings.analysisOllamaURL.host == "127.0.0.1")
        let local = HomeClerkPipeline.analyzer(.ollama, settings: settings, taxonomy: TestData.taxonomy, profile: .empty, ledger: nil)
        #expect((local as? OllamaFacetAnalyzer)?.session === LocalReaderTransport.session)
        settings.ollamaModel = "example:cloud"
        #expect(settings.readerPolicyProblem(for: .ollama) != nil)
    }

    @Test func blockedFallbackAndReadinessAreExplained() {
        var settings = HomeClerkSettings()
        settings.localReadersOnly = true
        settings.aiProvider = .apple
        settings.fallbackProvider = .claude
        #expect(settings.analysisPrivacySummary.contains("Fallback blocked"))
        let readers = Readers(hasClaudeKey: true, appleIntelligence: false, ollamaInstalled: false)
        #expect(readers.problem(settings) != nil)
        settings.aiProvider = .claude
        settings.fallbackProvider = .apple
        #expect(Readers(hasClaudeKey: true, appleIntelligence: true, ollamaInstalled: false).problem(settings) == nil)
    }

    @Test func localTransportRefusesRedirectWithDocumentPayload() async throws {
        let original = try #require(URL(string: "http://127.0.0.1:11434/api/chat"))
        let response = try #require(HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil,
                                                   headerFields: ["Location": "https://remote.example/api/chat"]))
        var redirect = URLRequest(url: try #require(URL(string: "https://remote.example/api/chat")))
        redirect.httpMethod = "POST"
        redirect.httpBody = Data("PRIVATE DOCUMENT".utf8)
        let task = LocalReaderTransport.session.dataTask(with: original)
        defer { task.cancel() }
        let forwarded: URLRequest? = await withCheckedContinuation { continuation in
            LocalReaderTransport.NoRedirects().urlSession(LocalReaderTransport.session, task: task,
                willPerformHTTPRedirection: response, newRequest: redirect) { continuation.resume(returning: $0) }
        }
        #expect(forwarded == nil)
        #expect(LocalReaderTransport.session.configuration.connectionProxyDictionary?.isEmpty == true)
    }
}
