import Foundation
import Testing
@testable import HomeClerkKit

struct FinishingOutcomesTests {
    struct Failure: Error, CustomStringConvertible { var description: String { "Synthetic finishing failure" } }
    var facets: DocumentFacets {
        DocumentFacets(documentType: "Bill", area: "Utilities", vendor: "Example", dueDate: "2099-12-31", amount: 10)
    }
    func settings(_ temp: TempFolder) -> HomeClerkSettings {
        var result = HomeClerkSettings(basePath: temp.url)
        result.createReminders = true
        return result
    }
    func failing(_ settings: HomeClerkSettings) -> Finisher {
        var finisher = Finisher(settings)
        finisher.operations = .init(searchable: { _ in throw Failure() }, tags: { _, _ in throw Failure() },
                                    reminders: { _, _ in throw Failure() })
        return finisher
    }

    @Test func failuresAreStructuredPersistedPrivateAndDoNotUndoFiling() async throws {
        let temp = TempFolder()
        let file = temp.url.appendingPathComponent("filed.pdf")
        try TestPDF.make(file, pages: ["Filed document stays intact"])
        let before = try Data(contentsOf: file)
        let outcome = await failing(settings(temp)).finish(file, facets: facets, today: "2026-01-01", documentID: "document-1")
        #expect(outcome.failures.map(\.step) == [.searchable, .tags, .reminders])
        #expect(outcome.warnings.count == 3)
        #expect(outcome.reminders.isEmpty)
        #expect(try Data(contentsOf: file) == before)
        let records = try FinishingIssues(folder: temp.url).load()
        #expect(records.count == 1 && records[0].documentID == "document-1")
        #expect(records[0].failures == outcome.failures)
        let permissions = try FileManager.default.attributesOfItem(atPath: temp.url.appendingPathComponent(FinishingIssues.fileName).path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func selectiveRetryKeepsOtherFailuresAndDisabledSteps() async throws {
        let temp = TempFolder()
        var configuration = settings(temp)
        let file = temp.url.appendingPathComponent("filed.pdf")
        _ = await failing(configuration).finish(file, facets: facets, today: "2026-01-01", documentID: "id")
        var successful = Finisher(configuration)
        successful.operations = .init(searchable: { _ in Issue.record("Unrequested OCR ran") },
            tags: { _, _ in Issue.record("Unrequested tagging ran") }, reminders: { _, _ in ["created"] })
        let outcome = await successful.finish(file, facets: facets, today: "2026-01-01", documentID: "id", steps: [.reminders])
        #expect(outcome.reminders == ["created"] && outcome.failures.isEmpty)
        #expect(try FinishingIssues(folder: temp.url).load().first?.failures.map(\.step) == [.searchable, .tags])
        configuration.makeSearchable = false
        var disabled = Finisher(configuration)
        disabled.operations = successful.operations
        _ = await disabled.finish(file, facets: facets, today: "2026-01-01", documentID: "id", steps: [.searchable])
        #expect(try FinishingIssues(folder: temp.url).load().first?.failures.map(\.step) == [.searchable, .tags])
    }

    @Test func retryUsesCurrentIdentityPathAndDetailsAndReappliesTagsAfterOCR() async throws {
        let temp = TempFolder()
        let configuration = settings(temp)
        try FileManager.default.createDirectory(at: configuration.outboxFolder, withIntermediateDirectories: true)
        let file = configuration.outboxFolder.appendingPathComponent("renamed.pdf")
        try TestPDF.make(file, pages: ["Document was renamed and corrected"])
        let entry = DocumentIndex.Entry(documentID: "stable", path: file.path, source: "original.pdf", pages: [1, 1],
            model: "test", confidence: 1, summary: "", facets: facets)
        let index = DocumentIndex(url: configuration.basePath.appendingPathComponent(DocumentIndex.fileName))
        try index.append(entry)
        let store = FinishingIssues(folder: temp.url)
        try store.update(documentID: "stable", path: "/do-not-use/stale.pdf", attempted: [.searchable],
                         failures: [.init(step: .searchable, detail: "OCR failed")])
        let calls = Locked<[String]>([])
        var worker = Finisher(configuration)
        worker.operations = .init(searchable: { url in calls.mutate { $0.append("OCR:\(url.path)") } },
            tags: { _, tags in calls.mutate { $0.append("tags:\(tags.joined(separator: ","))") } },
            reminders: { _, _ in Issue.record("Successful reminders were retried"); return [] })
        let before = try Data(contentsOf: index.url)
        let outcome = try await store.retry(documentID: "stable", settings: configuration, index: index, finisher: worker)
        #expect(outcome.failures.isEmpty)
        #expect(calls.value == ["OCR:\(file.path)", "tags:Utilities"])
        #expect(try store.load().isEmpty)
        #expect(try Data(contentsOf: index.url) == before)
    }

    @Test func corruptRepairHistoryIsReportedAndNeverOverwritten() async throws {
        let temp = TempFolder()
        let configuration = settings(temp)
        let storeFile = temp.url.appendingPathComponent(FinishingIssues.fileName)
        let corrupt = Data("not JSON".utf8)
        try PrivateFile.write(corrupt, to: storeFile)
        let outcome = await failing(configuration).finish(temp.url.appendingPathComponent("file.pdf"), facets: facets,
            today: "2026-01-01", documentID: "id")
        #expect(outcome.warnings.contains { $0.contains("history couldn't be saved") })
        #expect(try Data(contentsOf: storeFile) == corrupt)
    }

    @Test func automaticFilingReportsFinishingFailureAndKeepsCommittedDocument() async throws {
        let temp = TempFolder()
        var configuration = settings(temp)
        configuration.preserveOriginals = false
        try FileManager.default.createDirectory(at: configuration.inboxFolder, withIntermediateDirectories: true)
        let scan = configuration.inboxFolder.appendingPathComponent("scan.pdf")
        try TestPDF.make(scan, pages: [DocumentProcessorTests.billText])
        let index = DocumentIndex(url: temp.url.appendingPathComponent(DocumentIndex.fileName))
        let events = Locked<[PipelineEvent]>([])
        let analyzer = FakeAnalyzer("Fake", .init(documents: [DocumentProcessorTests.bill()]))
        let processor = DocumentProcessor(settings: configuration, taxonomy: TestData.taxonomy, analyzer: analyzer,
            duplicates: DuplicateDetector(duplicatesFolder: configuration.duplicatesFolder), index: index,
            finisher: failing(configuration), events: { event in events.mutate { $0.append(event) } }, today: { "2026-01-01" })
        await processor.process(scan)
        let entry = try #require(index.load().first)
        #expect(FileManager.default.fileExists(atPath: entry.path))
        #expect(!FileManager.default.fileExists(atPath: scan.path))
        #expect(events.value.contains { if case .filed = $0 { true } else { false } })
        #expect(events.value.contains { if case let .problem(detail) = $0 { detail.contains("needs attention") } else { false } })
        #expect(try FinishingIssues(folder: temp.url).load().first?.documentID == entry.documentID)
    }

    @Test func cancelledFinishingDoesNotCreateRemindersAndRecordsPendingSteps() async throws {
        let temp = TempFolder()
        var worker = Finisher(settings(temp))
        worker.operations = .init(searchable: { _ in Issue.record("Cancelled OCR ran") },
            tags: { _, _ in Issue.record("Cancelled tagging ran") },
            reminders: { _, _ in Issue.record("Cancelled reminder creation ran"); return [] })
        let finisher = worker
        let bill = facets
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await finisher.finish(temp.url.appendingPathComponent("file.pdf"), facets: bill,
                today: "2026-01-01", documentID: "id")
        }
        let outcome = await task.value
        #expect(outcome.failures.map(\.step) == [.searchable, .tags, .reminders])
        #expect(try FinishingIssues(folder: temp.url).load().first?.failures.count == 3)
    }

    @Test(arguments: ["outside", "symlink", "missing"])
    func retryRefusesUnsafeOrMissingIndexedFiles(kind: String) async throws {
        let temp = TempFolder()
        let configuration = settings(temp)
        try FileManager.default.createDirectory(at: configuration.outboxFolder, withIntermediateDirectories: true)
        let outside = try temp.file("outside.pdf")
        let link = configuration.outboxFolder.appendingPathComponent("link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let file = kind == "outside" ? outside : kind == "symlink" ? link : configuration.outboxFolder.appendingPathComponent("missing.pdf")
        let index = DocumentIndex(url: temp.url.appendingPathComponent(DocumentIndex.fileName))
        try index.append(.init(documentID: "id", path: file.path, source: "scan", pages: [], model: "test",
            confidence: 1, summary: "", facets: facets))
        let store = FinishingIssues(folder: temp.url)
        try store.update(documentID: "id", path: file.path, attempted: [.reminders], failures: [.init(step: .reminders, detail: "failed")])
        do {
            _ = try await store.retry(documentID: "id", settings: configuration, index: index, finisher: failing(configuration))
            Issue.record("Unsafe or missing file was accepted")
        } catch { }
        #expect(try store.load().count == 1)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "x")
    }
}
