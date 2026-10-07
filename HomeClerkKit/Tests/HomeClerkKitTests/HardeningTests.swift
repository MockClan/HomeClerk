import Foundation
import Testing
@testable import HomeClerkKit

/// Regression tests for issues found reviewing the Swift port.
@Suite struct HardeningTests {
    let temp = TempFolder()

    /// Never finishes on its own; cancellation makes it fail the way a cancelled request does.
    struct HangingAnalyzer: FacetAnalyzer {
        let modelName = "Slow"
        let isPaid = false
        func analyze(ocrText: String, pageCount: Int, pdf: URL) async -> FacetAnalysis {
            try? await Task.sleep(for: .seconds(60))
            return .failed("Cancelled")
        }
    }

    @Test func stoppingMidAnalysisLeavesTheScanInTheInbox() async throws {
        let settings = HomeClerkSettings(values: ["basepath": .string(temp.url.path)])
        try FileManager.default.createDirectory(at: settings.inboxFolder, withIntermediateDirectories: true)
        let scan = settings.inboxFolder.appendingPathComponent("scan.pdf")
        try TestPDF.make(scan, pages: ["A page of text"])
        let processor = DocumentProcessor(
            settings: settings, taxonomy: TestData.taxonomy, analyzer: HangingAnalyzer(),
            duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder),
            index: DocumentIndex(url: temp.url.appendingPathComponent("index.jsonl")),
            finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "x", expirationLeadDays: 30),
            events: { _ in })
        let task = Task { await processor.process(scan) }
        try await Task.sleep(for: .milliseconds(800))
        task.cancel()
        await task.value
        #expect(FileManager.default.fileExists(atPath: scan.path))
        #expect(!FileManager.default.fileExists(atPath: settings.reviewFolder.appendingPathComponent("scan.pdf").path))
    }

    @Test func foldersAreMadePrivate() throws {
        let folder = temp.url.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: NSNumber(value: 0o755)])
        try PrivateFolder.secure(folder)
        let mode = (try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(mode == 0o700)
        try PrivateFolder.secure(temp.url.appendingPathComponent("New/Nested"))
        #expect(FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("New/Nested").path))
    }

    @Test func badNumbersDoNotCrash() {
        #expect(Int(checking: .nan) == nil && Int(checking: .infinity) == nil && Int(checking: 1e300) == nil)
        #expect(Int(checking: 3.9) == 3)
        let settings = HomeClerkSettings(values: ["ExpirationReminderLeadDays": .number(.infinity),
                                                 "MinConfidenceThreshold": .number(.nan)])
        #expect(settings.expirationReminderLeadDays == 30 && settings.minConfidenceThreshold == 0.70)
        // Two documents, so the page numbers matter (one document is always the whole scan)
        let reply = #"{"summary":"s","documents":[{"first_page":1e300,"last_page":-1e300,"confidence":0.9},{"first_page":3,"last_page":3,"confidence":0.9}]}"#
        let analysis = FacetSchema.parse(reply, pageCount: 3, modelName: "m")
        #expect(analysis.error != nil && analysis.documents.isEmpty)
    }

    @Test func deeplyNestedJSONIsRejected() {
        let deep = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        #expect(throws: (any Error).self) { try JSONValue(parsing: deep) }
        #expect((try? JSONValue(parsing: "[[[1]]]")) != nil)
    }

    @Test(arguments: ["0,1", "4,5", "3,2", "1.5,3", "1,2.5", "1e300,3"])
    func malformedPageRangesAreRejectedInsteadOfClamped(pair: String) {
        let numbers = pair.split(separator: ",")
        // A second document, so the page numbers matter (one document is always the whole scan)
        let reply = "{\"summary\":\"s\",\"documents\":[{\"first_page\":\(numbers[0]),\"last_page\":\(numbers[1]),\"confidence\":0.99},"
            + "{\"first_page\":3,\"last_page\":3,\"confidence\":0.99}]}"
        let analysis = FacetSchema.parse(reply, pageCount: 3, modelName: "test")
        #expect(analysis.error != nil && analysis.documents.isEmpty)
    }

    /// One document is the whole scan, whatever pages the model wrote (Apple's model has written
    /// 5337–5341 for a 5-page scan).
    @Test(arguments: ["5337,5341", "0,0", "3,2", "1,1"])
    func oneDocumentIsTheWholeScan(pair: String) {
        let numbers = pair.split(separator: ",")
        let reply = "{\"summary\":\"s\",\"documents\":[{\"first_page\":\(numbers[0]),\"last_page\":\(numbers[1]),\"confidence\":0.9}]}"
        let analysis = FacetSchema.parse(reply, pageCount: 5, modelName: "test")
        #expect(analysis.error == nil)
        #expect(analysis.documents.map { [$0.firstPage, $0.lastPage] } == [[1, 5]])
    }

    /// A document running past the last page loses nothing, so the end is trimmed rather than
    /// sending the scan to Review.
    @Test func anEndPastTheLastPageIsTrimmed() {
        let reply = "{\"summary\":\"s\",\"documents\":[{\"first_page\":1,\"last_page\":2,\"confidence\":0.9},"
            + "{\"first_page\":3,\"last_page\":9,\"confidence\":0.9}]}"
        let analysis = FacetSchema.parse(reply, pageCount: 4, modelName: "test")
        #expect(analysis.error == nil)
        #expect(analysis.documents.map(\.lastPage) == [2, 4])
        #expect(FacetDocument.pageCoverageProblem(analysis.documents, pageCount: 4) == nil)
    }

    @Test func foldersCannotLeaveOrganized() throws {
        let organizer = FileOrganizer(outbox: temp.url.appendingPathComponent("Organized"))
        let a = try organizer.organize(try temp.file("a.pdf"), folder: "../../Escaped", filename: "a.pdf")
        #expect(FileOrganizer.isInside(a, temp.url.appendingPathComponent("Organized")))
        #expect(a.deletingLastPathComponent().lastPathComponent == "-..-Escaped")
        let b = try organizer.organize(try temp.file("b.pdf"), folder: ".hidden", filename: "b.pdf")
        #expect(b.deletingLastPathComponent().lastPathComponent == "hidden")
        let c = try organizer.organize(try temp.file("c.pdf"), folder: "..", filename: "c.pdf")
        #expect(c.deletingLastPathComponent().lastPathComponent == "Uncategorized")
    }

    @Test func aScanThatCannotLeaveTheInboxIsNotHandedOverAgain() async throws {
        let inbox = temp.url.appendingPathComponent("Inbox")
        let handed = Locked<Int>(0)
        let watcher = InboxWatcher(inbox: inbox, debounceSeconds: 0, maxWriteWait: .seconds(5), events: { _ in },
                                   enqueue: { _ in handed.mutate { $0 += 1 } })
        try await watcher.start()
        let scan = inbox.appendingPathComponent("stuck.pdf")
        try TestPDF.make(scan, pages: ["Stuck"])
        for _ in 0..<100 where handed.value == 0 { try await Task.sleep(for: .milliseconds(50)) }
        await watcher.finished(scan)        // processed, but the file is still there
        await watcher.scan()
        try await Task.sleep(for: .milliseconds(300))
        #expect(handed.value == 1)

        try FileManager.default.removeItem(at: scan)   // once it's gone, a new file with the name is picked up
        await watcher.scan()
        try TestPDF.make(scan, pages: ["New"])
        await watcher.scan()
        for _ in 0..<100 where handed.value == 1 { try await Task.sleep(for: .milliseconds(50)) }
        await watcher.stop()
        #expect(handed.value == 2)
    }

    @Test func backfillSkipsPathsOutsideOrganized() async throws {
        let settings = HomeClerkSettings(values: ["basepath": .string(temp.url.path)])
        var entry = BackfillEntry(path: "../outside.pdf", sha256: "x", handCorrected: false)
        entry.action = .move
        entry.apply = true
        entry.facets = DocumentFacets()
        let plan = BackfillPlan(createdAt: Date(), organizedFolder: settings.outboxFolder.path, model: "m", entries: [entry])
        let result = try await BackfillApplier(
            finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "x", expirationLeadDays: 30),
            index: DocumentIndex(url: temp.url.appendingPathComponent("i.jsonl")),
            duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
            .apply(plan, undoFolder: temp.url)
        #expect(result.problems == ["../outside.pdf: outside the Organized folder — skipped"])
    }
}
