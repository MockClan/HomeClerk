import Foundation
import Testing
@testable import HomeClerkKit

@Suite struct PathSafetyTests {
    let temp = TempFolder()
    var settings: HomeClerkSettings { HomeClerkSettings(values: ["basepath": .string(temp.url.appendingPathComponent("Archive").path)]) }
    var index: DocumentIndex { DocumentIndex(url: settings.basePath.appendingPathComponent("index.jsonl")) }
    var actions: ReviewActions {
        ReviewActions(settings: settings, taxonomy: TestData.taxonomy,
            finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "x", expirationLeadDays: 30),
            index: index, duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
    }
    func directory(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    func link(_ url: URL, to target: URL) throws { try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target) }

    @Test(arguments: [false, true]) func filingRejectsCategoryLinksWithoutMovingSource(internalTarget: Bool) throws {
        try directory(settings.outboxFolder)
        let outside = internalTarget ? settings.outboxFolder.appendingPathComponent("Actual") : temp.url.appendingPathComponent("Outside")
        try directory(outside)
        try link(settings.outboxFolder.appendingPathComponent("Medical"), to: outside)
        let source = try temp.file("source.pdf", "Original scan")
        #expect(throws: FileOrganizer.OutsideOrganized.self) {
            try FileOrganizer(outbox: settings.outboxFolder).organize(source, folder: "Medical", filename: "scan.pdf")
        }
        #expect(try String(contentsOf: source, encoding: .utf8) == "Original scan")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func missingDescendantsAreAllowedButDanglingLinksAreRejected() throws {
        try directory(settings.outboxFolder)
        let missing = settings.outboxFolder.appendingPathComponent("New/Nested/scan.pdf")
        #expect(FileOrganizer.isInside(missing, settings.outboxFolder))
        let dangling = settings.outboxFolder.appendingPathComponent("Dangling")
        try link(dangling, to: temp.url.appendingPathComponent("Missing"))
        #expect(!FileOrganizer.isInside(dangling.appendingPathComponent("Nested/scan.pdf"), settings.outboxFolder))
        #expect(!FileOrganizer.isInside(settings.outboxFolder.appendingPathComponent("../Outside/scan.pdf"), settings.outboxFolder))
        #expect(!FileOrganizer.isInside(settings.basePath.appendingPathComponent("OrganizedOther/scan.pdf"), settings.outboxFolder))
    }

    @Test func rootLinkIsRejectedWithoutChangingTargetPermissions() throws {
        try directory(settings.basePath)
        let outside = temp.url.appendingPathComponent("Outside")
        try directory(outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
        try link(settings.outboxFolder, to: outside)
        #expect(!FileOrganizer.isInside(settings.outboxFolder.appendingPathComponent("doc.pdf"), settings.outboxFolder))
        #expect(throws: FileOrganizer.OutsideOrganized.self) { try PrivateFolder.secure(settings.outboxFolder) }
        #expect((try FileManager.default.attributesOfItem(atPath: outside.path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    }

    @Test func ancestorAliasesRemainUsable() throws {
        let actual = temp.url.appendingPathComponent("Actual")
        try directory(actual)
        let alias = temp.url.appendingPathComponent("Alias")
        try link(alias, to: actual)
        let root = alias.appendingPathComponent("Organized")
        #expect(FileOrganizer.isInside(root.appendingPathComponent("New/doc.pdf"), root))
        let result = try FileOrganizer(outbox: root).organize(try temp.file("scan.pdf"), folder: "New", filename: "doc.pdf")
        #expect(FileManager.default.fileExists(atPath: result.path))
    }

    @Test func linkedReviewPDFIsNotListedFiledOrCombined() async throws {
        try directory(settings.reviewFolder)
        let outside = temp.url.appendingPathComponent("outside.pdf")
        try TestPDF.make(outside, pages: ["Private outside document"])
        let scan = settings.reviewFolder.appendingPathComponent("scan.pdf")
        try link(scan, to: outside)
        #expect(actions.pendingScans().isEmpty)
        await #expect(throws: FileOrganizer.OutsideOrganized.self) {
            try await actions.fileInFolder(scan, folder: "Medical", document: nil, analysis: nil)
        }
        #expect(throws: FileOrganizer.OutsideOrganized.self) { try actions.sendBackToInbox(scan) }
        #expect(throws: FileOrganizer.OutsideOrganized.self) { try actions.combine([scan, scan]) }
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(index.load().isEmpty)
    }

    @Test func returnAndRefileRejectLinkedSource() async throws {
        try directory(settings.outboxFolder)
        let outside = try temp.file("outside.pdf", "Leave alone")
        let path = settings.outboxFolder.appendingPathComponent("scan.pdf")
        try link(path, to: outside)
        let entry = DocumentIndex.Entry(path: path.path, source: "scan", pages: [], model: "", confidence: 1, summary: "", facets: DocumentFacets())
        #expect(throws: FileOrganizer.OutsideOrganized.self) { try actions.returnToReview(entry) }
        await #expect(throws: FileOrganizer.OutsideOrganized.self) { try await actions.refile(entry, facets: DocumentFacets(), folder: "Medical") }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "Leave alone")
    }

    @Test func undoRechecksDestinationAfterFolderBecomesLink() async throws {
        try directory(settings.reviewFolder)
        let scan = settings.reviewFolder.appendingPathComponent("scan.pdf")
        try TestPDF.make(scan, pages: ["Fictional scan"])
        let filing = try await actions.fileInFolder(scan, folder: "Medical", document: nil, analysis: nil)
        try FileManager.default.removeItem(at: settings.reviewFolder)
        let outside = temp.url.appendingPathComponent("Outside")
        try directory(outside)
        try link(settings.reviewFolder, to: outside)
        #expect(throws: FileOrganizer.OutsideOrganized.self) { try actions.undo(filing) }
        #expect(FileManager.default.fileExists(atPath: filing.destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func emptyFolderCleanupDoesNotFollowLinks() throws {
        try directory(settings.outboxFolder)
        let outside = temp.url.appendingPathComponent("Outside")
        try directory(outside.appendingPathComponent("Empty"))
        try link(settings.outboxFolder.appendingPathComponent("Linked"), to: outside)
        BackfillApplier.removeEmptyFolders(settings.outboxFolder)
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("Empty").path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: settings.outboxFolder.appendingPathComponent("Linked").path)) != nil)
    }

    @Test func recoveryRejectsLinkedOutputAncestorEvenWhenTargetIsInsideArchive() throws {
        try directory(settings.reviewFolder)
        let scan = settings.reviewFolder.appendingPathComponent("scan.pdf")
        try TestPDF.make(scan, pages: ["Fictional scan"])
        let to = try FileOrganizer(outbox: settings.outboxFolder).destination(folder: "Medical", filename: "filed.pdf")
        let record = DocumentIndex.Entry(path: to.path, source: "scan", pages: [], model: "", confidence: 1, summary: "", facets: DocumentFacets())
        let transaction = FilingTransaction(settings: settings, index: index, checkpoint: {
            if case .placed = $0 { throw FilingTransaction.Interrupted() }
        })
        #expect(throws: FilingTransaction.Interrupted.self) {
            try transaction.execute(source: scan, outputs: [.init(destination: to, entry: record)])
        }
        let actual = settings.outboxFolder.appendingPathComponent("Actual")
        try FileManager.default.moveItem(at: to.deletingLastPathComponent(), to: actual)
        try link(to.deletingLastPathComponent(), to: actual)
        #expect(throws: (any Error).self) { try FilingTransaction(settings: settings, index: index).recover() }
        #expect(FileManager.default.fileExists(atPath: scan.path))
        #expect(FileManager.default.fileExists(atPath: actual.appendingPathComponent("filed.pdf").path))
        #expect(index.load().isEmpty)
    }

    @Test func backfillSkipsLinksBeforeAnalysis() async throws {
        try directory(settings.outboxFolder)
        let outside = try temp.file("outside.pdf", "Never analyze")
        try link(settings.outboxFolder.appendingPathComponent("linked.pdf"), to: outside)
        let planner = BackfillPlanner(settings: settings, taxonomy: TestData.taxonomy, profile: HouseholdProfile())
        #expect(planner.selectFiles().isEmpty)
        let analyzer = FakeAnalyzer("Fake", .failed("Should never be called"))
        let planned = await planner.planOne("linked.pdf", handCorrected: false, analyzer: analyzer)
        #expect(planned.reason.contains("symbolic link"))
        #expect(analyzer.calls == 0)
    }

    @Test func processorRejectsLinkedScanBeforeReadingOrAnalyzing() async throws {
        try directory(settings.inboxFolder)
        let outside = try temp.file("outside.pdf", "No paid analysis")
        let scan = settings.inboxFolder.appendingPathComponent("scan.pdf")
        try link(scan, to: outside)
        let analyzer = FakeAnalyzer("Fake", .failed("Should never be called"))
        let events = Locked<[PipelineEvent]>([])
        let processor = DocumentProcessor(settings: settings, taxonomy: TestData.taxonomy, analyzer: analyzer,
            duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder), index: index,
            finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "x", expirationLeadDays: 30),
            events: { event in events.mutate { $0.append(event) } })
        await processor.process(scan)
        #expect(analyzer.calls == 0)
        #expect(events.value.contains { if case .problem = $0 { true } else { false } })
        #expect(try String(contentsOf: outside, encoding: .utf8) == "No paid analysis")
    }

    /// A HomeClerk folder moved to another drive, with a link left where it was, still starts;
    /// a link inside it is still refused.
    @Test func aLinkedHomeClerkFolderStartsButLinksInsideItDont() async throws {
        let real = temp.url.appendingPathComponent("ExternalDrive/HomeClerk")
        try FileManager.default.createDirectory(at: real.appendingPathComponent("Organized"), withIntermediateDirectories: true)
        let linked = temp.url.appendingPathComponent("HomeHomeClerk")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        let elsewhere = temp.url.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: real.appendingPathComponent("Organized/Sneaky"), withDestinationURL: elsewhere)
        #expect(!FileOrganizer.isInside(real.appendingPathComponent("Organized/Sneaky/x.pdf"), real))

        let settings = HomeClerkSettings(values: ["basepath": .string(linked.path), "aiprovider": .string("Apple"),
                                                 "fallbackprovider": .string("")])
        #expect(settings.basePath.resolvingSymlinksInPath().path == real.resolvingSymlinksInPath().path)
        let events = Locked<[PipelineEvent]>([])
        let pipeline = try HomeClerkPipeline(settings: settings, taxonomy: TestData.taxonomy, events: { event in events.mutate { $0.append(event) } })
        try await pipeline.start()
        await pipeline.stop()
        #expect(events.value.contains { if case .ready = $0 { true } else { false } })
    }
}
