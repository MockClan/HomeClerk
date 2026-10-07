import Foundation
import PDFKit
import Testing
@testable import HomeClerkKit

@Suite struct BudgetTests {
    let temp = TempFolder()

    @Test func stopsAtTheMonthsLimitSoTheFallbackTakesOver() async {
        let ledger = UsageLedger(url: temp.url.appendingPathComponent("usage.jsonl"))
        let success = ResilientFacetAnalyzerTests.success("Acme_Power")
        let claude = FakeAnalyzer("Claude test", success)
        let budgeted = BudgetedAnalyzer(claude, ledger: ledger, limit: 1)

        // Under the limit: Claude is asked
        #expect(await budgeted.analyze(ocrText: "", pageCount: 1, pdf: URL(fileURLWithPath: "/x.pdf")).error == nil)
        #expect(claude.calls == 1)

        // A big call this month uses up the dollar
        ledger.record(model: "claude-opus-5-5", input: 1_000_000, output: 100_000, cacheWrite: 0, cacheRead: 0)
        #expect(ledger.spent() >= 1)
        let fallback = FakeAnalyzer("Ollama test", success)
        let result = await ResilientFacetAnalyzer(primary: budgeted, fallback: fallback, delay: { _ in })
            .analyze(ocrText: "", pageCount: 1, pdf: URL(fileURLWithPath: "/x.pdf"))
        #expect(claude.calls == 1 && fallback.calls == 1)
        #expect(result.usedFallback && result.primaryError?.contains("limit") == true)
    }

    @Test func limitIsASettingClampedToSensibleValues() {
        #expect(HomeClerkSettings(values: ["claudemonthlylimit": .number(5)]).claudeMonthlyLimit == 5)
        #expect(HomeClerkSettings(values: ["claudemonthlylimit": .number(-3)]).claudeMonthlyLimit == 0)
        #expect(HomeClerkSettings().claudeMonthlyLimit == 0)
    }
}

@Suite struct ReturnToReviewTests {
    let temp = TempFolder()
    var settings: HomeClerkSettings { HomeClerkSettings(values: ["basepath": .string(temp.url.path)]) }

    @Test func sendsAFiledDocumentBackWithItsDetailsAndUndoRestoresIt() throws {
        let duplicates = DuplicateDetector(duplicatesFolder: settings.duplicatesFolder)
        let actions = ReviewActions(settings: settings, taxonomy: TestData.taxonomy,
                                    finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false,
                                                       remindersList: "x", expirationLeadDays: 30),
                                    index: DocumentIndex(url: temp.url.appendingPathComponent("index.jsonl")),
                                    duplicates: duplicates)
        let filed = settings.outboxFolder.appendingPathComponent("Receipts/receipt.pdf")
        try FileManager.default.createDirectory(at: filed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TestPDF.make(filed, pages: ["One", "Two"])
        let entry = DocumentIndex.Entry(path: filed.path, source: "scan.pdf", pages: [1, 2], model: "Test", confidence: 0.8,
                                        summary: "A receipt.", facets: DocumentFacets(documentType: "Receipt", vendor: "Acme_Store"))

        let returned = try actions.returnToReview(entry)
        #expect(!FileManager.default.fileExists(atPath: filed.path))
        let pending = try #require(actions.pendingScans().first)
        #expect(pending.reason == "You sent this back from Receipts to file again.")
        #expect(pending.document?.facets.vendor == "Acme_Store" && pending.document?.lastPage == 2)

        try actions.undo(returned)
        #expect(FileManager.default.fileExists(atPath: filed.path))
        #expect(actions.pendingScans().isEmpty)
    }
}

@Suite struct ReadersTests {
    @Test func firstRunPrefersClaudeWithAKeyThenTheFreeReaders() {
        #expect(Readers(hasClaudeKey: true, appleIntelligence: true, ollamaInstalled: true).firstRunChoice == (.claude, .apple))
        #expect(Readers(hasClaudeKey: false, appleIntelligence: true, ollamaInstalled: false).firstRunChoice == (.apple, nil))
        #expect(Readers(hasClaudeKey: false, appleIntelligence: false, ollamaInstalled: true).firstRunChoice == (.ollama, nil))
        #expect(Readers(hasClaudeKey: false, appleIntelligence: false, ollamaInstalled: false).firstRunChoice == (.claude, nil))
    }

    @Test func explainsWhenNothingConfiguredCanRead() {
        var settings = HomeClerkSettings()
        settings.aiProvider = .claude
        settings.fallbackProvider = .ollama
        let bare = Readers(hasClaudeKey: false, appleIntelligence: false, ollamaInstalled: false)
        #expect(bare.problem(settings) == "Claude needs an Anthropic API key, and the fallback can't run either.")
        #expect(Readers(hasClaudeKey: false, appleIntelligence: false, ollamaInstalled: true).problem(settings) == nil)
        settings.fallbackProvider = nil
        #expect(bare.problem(settings)?.hasSuffix("and there's no fallback.") == true)
    }
}
