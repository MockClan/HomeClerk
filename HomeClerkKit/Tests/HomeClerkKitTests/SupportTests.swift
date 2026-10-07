import Foundation
import Testing
@testable import HomeClerkKit

@Suite struct SettingsTests {
    /// A throwaway preferences domain, never the app's real one.
    final class TestDefaults {
        let name = "homeclerk.tests.\(UUID().uuidString)"
        lazy var defaults = UserDefaults(suiteName: name)!
        deinit { defaults.removePersistentDomain(forName: name) }
    }

    @Test func defaultsMatchWhatTheAppShippedWith() {
        let settings = HomeClerkSettings()
        #expect(settings.aiProvider == .claude && settings.fallbackProvider == .ollama)
        #expect(settings.basePath == HomeClerkSettings.defaultBasePath)
        #expect(settings.inboxFolder == settings.basePath.appendingPathComponent("Inbox"))
    }

    @Test func savesOnlyWhatDiffersAndLoadsItBack() {
        let test = TestDefaults()
        let store = SettingsStore(defaults: test.defaults)
        var settings = HomeClerkSettings()
        settings.aiProvider = .ollama
        settings.createReminders = true
        settings.expirationReminderLeadDays = 14
        store.save(settings)
        #expect(test.defaults.string(forKey: "AiProvider") == "Ollama")
        #expect(test.defaults.object(forKey: "ClaudeModel") == nil)   // unchanged → not stored
        #expect(store.load(environment: [:]) == settings)

        settings.aiProvider = .claude                                     // back to the default → cleared
        store.save(settings)
        #expect(test.defaults.object(forKey: "AiProvider") == nil)
    }

    @Test func environmentOverridesStoredSettings() {
        let test = TestDefaults()
        let store = SettingsStore(defaults: test.defaults)
        let settings = store.load(environment: ["HOMECLERK_HomeClerk__BasePath": "/tmp/scratch",
                                                "HOMECLERK_HomeClerk__AiProvider": "ollama",
                                                "HOMECLERK_HomeClerk__FallbackProvider": ""])
        #expect(settings.basePath.path == "/tmp/scratch" && settings.aiProvider == .ollama && settings.fallbackProvider == nil)
    }

    @Test func unusableValuesKeepTheirDefaults() {
        let settings = HomeClerkSettings(values: ["AiProvider": .string("OpenAI"), "MinConfidenceThreshold": .number(7),
                                                 "OllamaBaseUrl": .string("not a url"), "ExpirationReminderLeadDays": .string("soon")])
        #expect(settings.aiProvider == .claude && settings.minConfidenceThreshold == 1)
        #expect(settings.ollamaBaseURL.absoluteString == "http://localhost:11434" && settings.expirationReminderLeadDays == 30)
    }
}

@Suite struct UsageLedgerTests {
    @Test func estimatesCostFromPublishedPrices() {
        // One test-set document on Sonnet 5.5: 5,508 input + 278 output + 4,771 cache-write tokens
        let cost = UsageLedger.estimateCost(model: "claude-sonnet-5-5", input: 5508, output: 278, cacheWrite: 4771, cacheRead: 0)
        var value = cost!, rounded = Decimal()
        NSDecimalRound(&rounded, &value, 4, .plain)
        #expect(rounded == Decimal(string: "0.0257"))
    }

    @Test func unknownModelHasNoCost() {
        #expect(UsageLedger.estimateCost(model: "some-future-model", input: 1000, output: 1000, cacheWrite: 0, cacheRead: 0) == nil)
    }

    @Test func readsTheLinesTheCurrentAppWrites() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try #"""
            {"at":"2026-03-02T08:15:00.1234567-05:00","model":"claude-sonnet-5-5","input":10,"output":2,"cache_write":0,"cache_read":0,"cost":0.00004}
            {"at":"2026-03-02T08:16:30.98765-05:00","model":"claude-sonnet-5-5","input":1,"output":1,"cache_write":0,"cache_read":3,"cost":null}

            """#.write(to: url, atomically: true, encoding: .utf8)
        let entries = try UsageLedger.load(from: url)
        #expect(entries.count == 2 && entries[0].input == 10 && entries[1].cost == nil)
        UsageLedger(url: url).record(model: "claude-sonnet-5-5", input: 1, output: 1, cacheWrite: 0, cacheRead: 0)
        #expect(try UsageLedger.load(from: url).count == 3)
    }
}
