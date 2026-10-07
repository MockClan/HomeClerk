import Foundation
import PDFKit
import Testing
@testable import HomeClerkKit

/// The processor end to end on real PDFs in a temporary folder, with a fake analyzer.
// Vision OCR can stall when many synthetic processors render concurrently.
@Suite(.serialized) struct DocumentProcessorTests {
    let temp = TempFolder()
    let recorded = Locked<[PipelineEvent]>([])

    var settings: HomeClerkSettings { HomeClerkSettings(values: ["basepath": .string(temp.url.path)]) }

    func processor(_ analyzer: any FacetAnalyzer, preserveOriginals: Bool = true) -> DocumentProcessor {
        let events = recorded
        var configuration = settings
        configuration.preserveOriginals = preserveOriginals
        return DocumentProcessor(
            settings: configuration, taxonomy: TestData.taxonomy, analyzer: analyzer,
            duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder),
            index: DocumentIndex(url: temp.url.appendingPathComponent("index.jsonl")),
            finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "x",
                               expirationLeadDays: 30),
            events: { event in events.mutate { $0.append(event) } }, today: { "2026-04-01" })
    }

    static let billText = "ACME POWER\nELECTRIC SERVICE STATEMENT\nAccount 0000-1111\nStatement date February 3 2026\n"
        + "Amount due 88.12\nPlease pay by February 24 2026\nThank you for being a valued customer of Acme Power"

    static func bill(confidence: Double = 0.95, pages: ClosedRange<Int> = 1...1, vendor: String = "Acme_Power") -> FacetDocument {
        FacetDocument(firstPage: pages.lowerBound, lastPage: pages.upperBound,
                      facets: DocumentFacets(documentType: "Bill", area: "Utilities", vendor: vendor, description: "Electric_Bill",
                                             documentDate: "2026-02-03", amount: Decimal(string: "88.12")),
                      confidence: confidence)
    }

    func scan(_ name: String, pages: [String] = [billText]) throws -> URL {
        let inbox = settings.inboxFolder
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let url = inbox.appendingPathComponent(name)
        try TestPDF.make(url, pages: pages)
        return url
    }

    func files(in folder: URL) -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".pdf") || $0.hasSuffix(".txt") || $0.hasSuffix(".json") }.sorted()
    }

    @Test func filesADocumentAndRecordsIt() async throws {
        let source = try scan("scan1.pdf")
        await processor(FakeAnalyzer("Fake", FacetAnalysis(documents: [Self.bill()], summary: "A bill."))).process(source)

        #expect(files(in: settings.outboxFolder) == ["Bills - Utilities/2026-02-03-Acme_Power-Electric_Bill-88.12.pdf"])
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(files(in: settings.originalsFolder) == [".scan1.pdf.original.json", "scan1.pdf"])
        let entry = try #require(DocumentIndex(url: temp.url.appendingPathComponent("index.jsonl")).load().first)
        #expect(entry.source == "scan1.pdf" && entry.pages == [1, 1] && entry.facets.vendor == "Acme_Power")
        let kinds = recorded.value.map { event -> String in
            switch event {
            case .stage(_, let stage, _): stage.rawValue
            case .filed(_, let folder, _, _, _): "filed:\(folder)"
            default: "\(event)"
            }
        }
        #expect(kinds == ["reading", "filing", "filed:Bills - Utilities"])
    }

    @Test func theSameFileTwiceIsAnExactDuplicate() async throws {
        let first = try scan("scan1.pdf")
        let copy = settings.inboxFolder.appendingPathComponent("copy.pdf")
        try FileManager.default.copyItem(at: first, to: copy)
        let analyzer = FakeAnalyzer("Fake", FacetAnalysis(documents: [Self.bill()], summary: "A bill."))
        let p = processor(analyzer)
        await p.process(first)
        await p.process(copy)

        #expect(analyzer.calls == 1)   // no second AI call
        #expect(files(in: settings.duplicatesFolder).contains("copy.pdf"))
        let reason = try String(contentsOf: settings.duplicatesFolder.appendingPathComponent("copy.reason.txt"), encoding: .utf8)
        #expect(reason.hasPrefix("Duplicate of: Bills - Utilities/2026-02-03-Acme_Power-Electric_Bill-88.12.pdf\nWhy: identical file"))
    }

    @Test(.requiresOCR) func aRescanWithTheSameTextAndFactsIsANearDuplicate() async throws {
        let first = try scan("scan1.pdf")
        let rescan = try scan("scan2.pdf", pages: [Self.billText + "\n"])   // different bytes, same text
        let p = processor(FakeAnalyzer("Fake", FacetAnalysis(documents: [Self.bill()], summary: "A bill."),
                                       FacetAnalysis(documents: [Self.bill()], summary: "A bill.")))
        await p.process(first)
        await p.process(rescan)
        #expect(files(in: settings.duplicatesFolder).contains("scan2.pdf"))
    }

    @Test func lowConfidenceGoesToReviewWithAProposal() async throws {
        let source = try scan("scan1.pdf")
        await processor(FakeAnalyzer("Fake", FacetAnalysis(documents: [Self.bill(confidence: 0.5)], summary: "Unsure.")))
            .process(source)
        #expect(files(in: settings.reviewFolder) == ["scan1.pdf", "scan1.proposal.json", "scan1.reason.txt"])
        let reason = try String(contentsOf: settings.reviewFolder.appendingPathComponent("scan1.reason.txt"), encoding: .utf8)
        #expect(reason.hasPrefix("Confidence 50% below threshold 70%.\n\nUnsure.\n\nRun `HomeClerk review`"))
        #expect(ReviewProposal.load(for: settings.reviewFolder.appendingPathComponent("scan1.pdf"))?.documents.count == 1)
    }

    @Test func aPasswordProtectedScanWaitsInReviewUnread() async throws {
        let source = try scan("locked.pdf")
        try LockedPDFTests.make(source, password: "maple-42")
        let analyzer = FakeAnalyzer("Fake", FacetAnalysis(documents: [Self.bill()], summary: "A bill."))
        await processor(analyzer).process(source)
        #expect(analyzer.calls == 0)
        let reason = try String(contentsOf: settings.reviewFolder.appendingPathComponent("locked.reason.txt"), encoding: .utf8)
        #expect(reason == PDFTools.lockedReason)
    }

    @Test func theIndexHasAFiledDocumentBeforeItsAnnounced() async throws {
        let source = try scan("scan1.pdf")
        let index = DocumentIndex(url: temp.url.appendingPathComponent("index.jsonl"))
        let indexedWhenAnnounced = Locked<Bool?>(nil)
        let processor = DocumentProcessor(
            settings: settings, taxonomy: TestData.taxonomy,
            analyzer: FakeAnalyzer("Fake", FacetAnalysis(documents: [Self.bill()], summary: "A bill.")),
            duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder), index: index,
            finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "x",
                               expirationLeadDays: 30),
            events: { event in
                if case .filed(let path, _, _, _, _) = event {
                    indexedWhenAnnounced.mutate { $0 = index.load().contains { $0.path == path.path } }
                }
            }, today: { "2026-04-01" })
        await processor.process(source)
        #expect(indexedWhenAnnounced.value == true)
    }

    @Test func indexFailureDoesNotAnnounceFilingAndPreservesScanInReview() async throws {
        let source = try scan("scan1.pdf")
        try FileManager.default.createDirectory(at: temp.url.appendingPathComponent("index.jsonl"), withIntermediateDirectories: true)
        await processor(FakeAnalyzer("Fake", FacetAnalysis(documents: [Self.bill()], summary: "A bill.")), preserveOriginals: false).process(source)
        #expect(!recorded.value.contains { if case .filed = $0 { true } else { false } })
        #expect(PDFDocument(url: settings.reviewFolder.appendingPathComponent("scan1.pdf"))?.pageCount == 1)
        #expect(files(in: settings.outboxFolder).isEmpty)
    }

    @Test func analysisFailureGoesToReview() async throws {
        let source = try scan("scan1.pdf")
        await processor(FakeAnalyzer("Fake", .failed("Claude declined to analyze this document (bio)"))).process(source)
        let reason = try String(contentsOf: settings.reviewFolder.appendingPathComponent("scan1.reason.txt"), encoding: .utf8)
        #expect(reason == "Claude declined to analyze this document (bio)")
        #expect(recorded.value.contains { if case .review(_, let r, _, _, _) = $0 { r == reason } else { false } })
    }

    @Test func aScanOfTwoDocumentsIsSplit() async throws {
        let source = try scan("scan1.pdf", pages: [Self.billText, "Second page of the bill", "ACME TIRE RECEIPT\nOil change 45.00"])
        let receipt = FacetDocument(firstPage: 3, lastPage: 3,
                                    facets: DocumentFacets(documentType: "Receipt", area: "Vehicle", tags: ["maintenance"],
                                                           vendor: "Acme_Tire", description: "Oil_Change", documentDate: "2026-02-09",
                                                           amount: 45, vehicle: "2021_Toyota_RAV4"),
                                    confidence: 0.9)
        await processor(FakeAnalyzer("Fake", FacetAnalysis(documents: [Self.bill(pages: 1...2), receipt], summary: "Two.")))
            .process(source)

        let filed = files(in: settings.outboxFolder)
        #expect(filed == ["Bills - Utilities/2026-02-03-Acme_Power-Electric_Bill-88.12.pdf",
                          "Vehicle - Maintenance/2026-02-09-Acme_Tire-2021_Toyota_RAV4-Oil_Change-45.00.pdf"])
        #expect(PDFDocument(url: settings.outboxFolder.appendingPathComponent(filed[0]))?.pageCount == 2)
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func aScanThatDisappearedIsSkipped() async {
        let missing = settings.inboxFolder.appendingPathComponent("gone.pdf")
        await processor(FakeAnalyzer("Fake")).process(missing)
        #expect(recorded.value == [.skipped(source: missing)])
    }

    // Vision's synchronous requests can stall when all parameterized OCR cases run together.
    @Test(.serialized, arguments: PageCoverageTests.invalidCases)
    func invalidPageCoveragePreservesTheWholeScanInReview(ranges: [[Int]]) async throws {
        let source = try scan("scan.pdf", pages: ["First page", "Important middle page", "Last page"])
        let original = try Data(contentsOf: source)
        let analysis = FacetAnalysis(documents: PageCoverageTests.documents(ranges), summary: "Proposed split")
        await processor(FakeAnalyzer("Fake", analysis), preserveOriginals: false).process(source)

        let review = settings.reviewFolder.appendingPathComponent("scan.pdf")
        #expect(try Data(contentsOf: review) == original)
        #expect(PDFDocument(url: review)?.pageCount == 3)
        #expect(ReviewProposal.load(for: review)?.documents == analysis.documents)
        #expect(files(in: settings.outboxFolder).isEmpty)
        #expect(DocumentIndex(url: temp.url.appendingPathComponent("index.jsonl")).load().isEmpty)
        #expect(DuplicateDetector(duplicatesFolder: settings.duplicatesFolder).exactDuplicate(sha256: BackfillApplier.sha256(original)) == nil)
        #expect(!recorded.value.contains { if case .filed = $0 { true } else { false } })
        #expect(try String(contentsOf: ReviewProposal.reasonURL(for: review), encoding: .utf8).hasPrefix("Page ranges need review:"))
    }
}

@Suite struct PageCoverageTests {
    static let invalidCases: [[[Int]]] = [
        [[1, 1], [3, 3]], // middle page omitted
        [[1, 2]], // final page omitted, including a single-document proposal
        [[2, 3]], // first page omitted
        [[1, 2], [2, 3]], // overlapping page
        [[2, 1], [2, 3]], // reversed range
        [[0, 1], [2, 3]], // invalid lower bound
        [[1, 2], [3, 4]], // beyond the scan
        [] // no documents must never authorize deletion
    ]

    static func documents(_ ranges: [[Int]]) -> [FacetDocument] {
        ranges.map { FacetDocument(firstPage: $0[0], lastPage: $0[1], facets: DocumentFacets(), confidence: 1) }
    }

    @Test func coverageAcceptsUnorderedCompleteRanges() {
        #expect(FacetDocument.pageCoverageProblem(Self.documents([[3, 3], [1, 2]]), pageCount: 3) == nil)
        #expect(FacetDocument.pageCoverageProblem(Self.documents([[1, 3]]), pageCount: 3) == nil)
        #expect(FacetDocument.pageCoverageProblem(Self.documents([[1, Int.max]]), pageCount: 3) != nil)
        #expect(FacetDocument.pageCoverageProblem(Self.documents([[1, 1]]), pageCount: 0) != nil)
    }

    @Test(arguments: invalidCases)
    func manualSplitRejectsInvalidCoverageBeforeChangingFiles(ranges: [[Int]]) async throws {
        let temp = TempFolder()
        let settings = HomeClerkSettings(values: ["basepath": .string(temp.url.path)])
        try FileManager.default.createDirectory(at: settings.reviewFolder, withIntermediateDirectories: true)
        let scan = settings.reviewFolder.appendingPathComponent("scan.pdf")
        try TestPDF.make(scan, pages: ["First", "Middle", "Last"])
        let original = try Data(contentsOf: scan)
        let index = DocumentIndex(url: temp.url.appendingPathComponent("index.jsonl"))
        let actions = ReviewActions(settings: settings, taxonomy: TestData.taxonomy,
            finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "test", expirationLeadDays: 30),
            index: index, duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
        await #expect(throws: ReviewActions.SplitError.self) {
            try await actions.fileSplit(scan, documents: Self.documents(ranges), analysis: nil)
        }
        #expect(try Data(contentsOf: scan) == original)
        #expect(index.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: settings.outboxFolder.path))
    }
}

@Suite struct InboxWatcherTests {
    @Test func reportsAndHandsOverNewPDFsOnce() async throws {
        let temp = TempFolder()
        let inbox = temp.url.appendingPathComponent("Inbox")
        let handed = Locked<[String]>([])
        let detected = Locked<[String]>([])
        let watcher = InboxWatcher(inbox: inbox, debounceSeconds: 0, maxWriteWait: .seconds(5),
                                   events: { if case .detected(let url) = $0 { detected.mutate { $0.append(url.lastPathComponent) } } },
                                   enqueue: { url in handed.mutate { $0.append(url.lastPathComponent) } })
        try await watcher.start()
        try TestPDF.make(inbox.appendingPathComponent("scan.pdf"), pages: ["Hello"])
        try "not a pdf".write(to: inbox.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        for _ in 0..<100 where handed.value.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        await watcher.scan()   // a second look must not hand it over again
        try await Task.sleep(for: .milliseconds(200))
        await watcher.stop()
        #expect(detected.value == ["scan.pdf"])
        #expect(handed.value == ["scan.pdf"])
    }
}

@Suite struct OllamaMonitorTests {
    @Test func untaggedNameMeansLatest() {
        #expect(OllamaMonitor.hasModel(["qwen3-vl:8b-instruct", "llama3.2:latest"], "llama3.2"))
        #expect(OllamaMonitor.hasModel(["qwen3-vl:8b-instruct"], "qwen3-vl:8b-instruct"))
        #expect(!OllamaMonitor.hasModel(["qwen3-vl:8b-instruct"], "qwen3-vl:8b"))
    }

    @Test func roleFollowsTheProviders() {
        #expect(OllamaMonitor.role(for: HomeClerkSettings(values: ["aiprovider": .string("ollama")])) == .primary)
        #expect(OllamaMonitor.role(for: HomeClerkSettings(values: ["fallbackprovider": .string("Ollama")])) == .fallback)
        #expect(OllamaMonitor.role(for: HomeClerkSettings(values: ["fallbackprovider": .string("Apple")])) == nil)
    }
}

@Suite struct PauseGateTests {
    @Test func holdsWaitersUntilOpened() async throws {
        let gate = PauseGate()
        await gate.wait()   // open: returns at once

        await gate.close()
        let passed = Locked(false)
        let waiter = Task {
            await gate.wait()
            passed.mutate { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!passed.value)

        await gate.open()
        await waiter.value
        #expect(passed.value)
        #expect(await !gate.isClosed)
    }
}

@Suite struct FolderLockTests {
    @Test func onlyOneHolderPerFolder() throws {
        let temp = TempFolder()
        let first = FolderLock(folder: temp.url), second = FolderLock(folder: temp.url)
        try first.acquire()
        #expect(throws: FolderLock.Held.self) { try second.acquire() }
        first.release()
        try second.acquire()   // free once the first lets go
        second.release()
    }
}
