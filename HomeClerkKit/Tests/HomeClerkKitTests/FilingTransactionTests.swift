import Foundation
import PDFKit
import Testing
@testable import HomeClerkKit

@Suite struct FilingTransactionTests {
    let temp = TempFolder()
    var settings: HomeClerkSettings { HomeClerkSettings(values: ["basepath": .string(temp.url.path)]) }
    var index: DocumentIndex { DocumentIndex(url: temp.url.appendingPathComponent("index.jsonl")) }

    func scan() throws -> URL {
        try FileManager.default.createDirectory(at: settings.reviewFolder, withIntermediateDirectories: true)
        let source = settings.reviewFolder.appendingPathComponent("scan.pdf")
        try TestPDF.make(source, pages: ["Fictional page one", "Fictional page two"])
        try PrivateFile.write(Data("Needs review".utf8), to: ReviewProposal.reasonURL(for: source))
        try ReviewProposal.save(ReviewActionsTests.proposal(), for: source)
        return source
    }

    func output(_ name: String, pages: ClosedRange<Int>? = nil) throws -> FilingTransaction.Output {
        let destination = try FileOrganizer(outbox: settings.outboxFolder).destination(folder: "Medical", filename: name)
        return .init(destination: destination, entry: .init(path: destination.path, source: "scan.pdf", pages: [],
            model: "test", confidence: 1, summary: "Fictional", facets: DocumentFacets()), pages: pages)
    }

    @Test func indexFailurePreservesSourceNotesAndRollsBackEveryPart() throws {
        let source = try scan(), original = try Data(contentsOf: source)
        let parts = try [output("one.pdf", pages: 1...1), output("two.pdf", pages: 2...2)]
        // A directory where the index should be forces an actual read/write failure.
        try FileManager.default.createDirectory(at: index.url, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try FilingTransaction(settings: settings, index: index).execute(source: source, outputs: parts, deleteSidecars: true)
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(ReviewProposal.load(for: source) != nil)
        #expect(FileManager.default.fileExists(atPath: ReviewProposal.reasonURL(for: source).path))
        #expect(parts.allSatisfy { !FileManager.default.fileExists(atPath: $0.destination.path) })
        #expect(try FilingTransaction(settings: settings, index: index).recover() == 0)
    }

    /// Interrupted with the source changed afterwards: recovery can't safely finish it.
    func stuckOperation() throws -> URL {
        let source = try scan(), part = try output("stuck.pdf")
        let transaction = FilingTransaction(settings: settings, index: index, checkpoint: {
            if case .placed = $0 { throw FilingTransaction.Interrupted() }
        })
        #expect(throws: FilingTransaction.Interrupted.self) { try transaction.execute(source: source, outputs: [part]) }
        try Data("Changed document".utf8).write(to: source)
        return source
    }

    @Test func onlyTheInterruptedScanCountsAsPending() throws {
        let source = try stuckOperation()
        let transaction = FilingTransaction(settings: settings, index: index)
        #expect(transaction.isPending(source: source))
        #expect(!transaction.isPending(source: settings.inboxFolder.appendingPathComponent("unrelated.pdf")))
        try Data().write(to: temp.url.appendingPathComponent(".homeclerk-operations/.DS_Store"))
        #expect(!transaction.isPending(source: settings.inboxFolder.appendingPathComponent("unrelated.pdf")))
    }

    /// Two index objects for one file — the old and new pipeline across a restart — appending at
    /// the same time keep every entry.
    @Test func twoIndexObjectsForOneFileDontLoseEntries() async throws {
        let url = temp.url.appendingPathComponent("shared.jsonl")
        func entry(_ i: Int) -> DocumentIndex.Entry {
            .init(path: "/fictional/\(i).pdf", source: "s.pdf", pages: [1, 1], model: "m", confidence: 1, summary: "", facets: DocumentFacets())
        }
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask { try? DocumentIndex(url: url).append(entry(i)) }
            }
        }
        #expect(DocumentIndex(url: url).load().count == 200)
    }

    @Test func hiddenFilesInTheRecoveryFolderAreIgnored() throws {
        let root = temp.url.appendingPathComponent(".homeclerk-operations")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        try Data().write(to: root.appendingPathComponent(".\(UUID().uuidString).icloud"))
        #expect(try FilingTransaction(settings: settings, index: index).recover() == 0)
        let report = FilingTransaction(settings: settings, index: index).recoverWhatIsSafe()
        #expect(report.recovered == 0 && report.preserved.isEmpty)
    }

    @Test func startupRecoveryKeepsAStuckOperationAndCarriesOn() throws {
        let source = try stuckOperation()
        // A second, healthy interruption alongside it still gets finished
        try FileManager.default.createDirectory(at: settings.inboxFolder, withIntermediateDirectories: true)
        let other = settings.inboxFolder.appendingPathComponent("other.pdf")
        try TestPDF.make(other, pages: ["Fictional other page"])
        let otherPart = try output("other.pdf")
        let interrupted = FilingTransaction(settings: settings, index: index, checkpoint: {
            if case .indexed = $0 { throw FilingTransaction.Interrupted() }
        })
        #expect(throws: FilingTransaction.Interrupted.self) { try interrupted.execute(source: other, outputs: [otherPart]) }

        let report = FilingTransaction(settings: settings, index: index).recoverWhatIsSafe()
        #expect(report.recovered == 1)
        #expect(report.preserved.count == 1)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: other.path))   // the healthy one finished
    }

    @Test func aStuckOperationDoesNotStopThePipelineStarting() async throws {
        _ = try stuckOperation()
        let events = Locked<[PipelineEvent]>([])
        // Apple's reader with no fallback: nothing reads the Keychain or calls a server
        let local = HomeClerkSettings(values: ["basepath": .string(temp.url.path), "aiprovider": .string("Apple"),
                                              "fallbackprovider": .string("")])
        let pipeline = try HomeClerkPipeline(settings: local, taxonomy: TestData.taxonomy, events: { event in events.mutate { $0.append(event) } })
        try await pipeline.start()
        await pipeline.stop()
        #expect(events.value.contains { if case .ready = $0 { true } else { false } })
        #expect(events.value.contains { if case .problem(let message) = $0 { message.contains("Library Health") } else { false } })
    }

    @Test(arguments: [0, 1, 2, 3]) func interruptionsRecoverAllOrNothing(point: Int) throws {
        let source = try scan()
        let parts = try [output("one.pdf", pages: 1...1), output("two.pdf", pages: 2...2)]
        let transaction = FilingTransaction(settings: settings, index: index, checkpoint: { checkpoint in
            switch (point, checkpoint) {
            case (0, .prepared), (1, .placed(0)), (2, .placed(1)), (3, .indexed): throw FilingTransaction.Interrupted()
            default: break
            }
        })
        #expect(throws: FilingTransaction.Interrupted.self) {
            try transaction.execute(source: source, outputs: parts, deleteSidecars: true)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try FilingTransaction(settings: settings, index: index).recover() == 1)
        #expect(try FilingTransaction(settings: settings, index: index).recover() == 0)
        if point == 3 {
            #expect(index.load().count == 2)
            #expect(!FileManager.default.fileExists(atPath: source.path))
            #expect(ReviewProposal.load(for: source) == nil)
            #expect(parts.allSatisfy { PDFDocument(url: $0.destination)?.pageCount == 1 })
        } else {
            #expect(index.load().isEmpty)
            #expect(ReviewProposal.load(for: source) != nil)
            #expect(parts.allSatisfy { !FileManager.default.fileExists(atPath: $0.destination.path) })
        }
    }

    @Test func conflictingSecondDestinationNeverDeletesUnrelatedFile() throws {
        let source = try scan()
        let parts = try [output("one.pdf", pages: 1...1), output("two.pdf", pages: 2...2)]
        try Data("Unrelated document".utf8).write(to: parts[1].destination)
        #expect(throws: (any Error).self) {
            try FilingTransaction(settings: settings, index: index).execute(source: source, outputs: parts)
        }
        #expect(!FileManager.default.fileExists(atPath: parts[0].destination.path))
        #expect(try String(contentsOf: parts[1].destination, encoding: .utf8) == "Unrelated document")
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(index.load().isEmpty)
    }

    @Test(arguments: [true, false]) func recoveryPreservesChangedDocuments(changeSource: Bool) throws {
        let source = try scan(), part = try output("copy.pdf")
        let transaction = FilingTransaction(settings: settings, index: index, checkpoint: {
            if case .placed = $0 { throw FilingTransaction.Interrupted() }
        })
        #expect(throws: FilingTransaction.Interrupted.self) { try transaction.execute(source: source, outputs: [part]) }
        try Data("Changed document".utf8).write(to: changeSource ? source : part.destination)
        #expect(throws: (any Error).self) { try FilingTransaction(settings: settings, index: index).recover() }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: part.destination.path))
    }

    @Test func manualFilingWithoutProposalIsIndexed() async throws {
        let source = try scan()
        let actions = ReviewActions(settings: settings, taxonomy: TestData.taxonomy,
            finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "x", expirationLeadDays: 30),
            index: index, duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
        let filing = try await actions.fileInFolder(source, folder: "Legal", document: nil, analysis: nil)
        #expect(DocumentLibrary.load(index).documents.map(\.path) == [filing.destination.path])
        #expect(!FileManager.default.fileExists(atPath: source.path))
        try actions.undo(filing)
        #expect(ReviewProposal.load(for: source) != nil)
    }

    @Test func manualSplitIndexFailureReturnsNoPartialFiling() async throws {
        let source = try scan()
        try FileManager.default.createDirectory(at: index.url, withIntermediateDirectories: true)
        let actions = ReviewActions(settings: settings, taxonomy: TestData.taxonomy,
            finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "x", expirationLeadDays: 30),
            index: index, duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
        let docs = [FacetDocument(firstPage: 1, lastPage: 1, facets: DocumentFacets(), confidence: 1),
                    FacetDocument(firstPage: 2, lastPage: 2, facets: DocumentFacets(), confidence: 1)]
        await #expect(throws: (any Error).self) { try await actions.fileSplit(source, documents: docs, analysis: nil) }
        #expect(PDFDocument(url: source)?.pageCount == 2)
        #expect(ReviewProposal.load(for: source) != nil)
        #expect((FileManager.default.subpaths(atPath: settings.outboxFolder.path) ?? []).filter { $0.hasSuffix(".pdf") }.isEmpty)
    }

    @Test func refilingIndexFailurePreservesOriginalLocation() async throws {
        let source = try output("old.pdf").destination
        try TestPDF.make(source, pages: ["Original document"])
        let original = try Data(contentsOf: source)
        let entry = DocumentIndex.Entry(path: source.path, source: "scan.pdf", pages: [], model: "test",
            confidence: 1, summary: "", facets: DocumentFacets())
        try FileManager.default.createDirectory(at: index.url, withIntermediateDirectories: true)
        let actions = ReviewActions(settings: settings, taxonomy: TestData.taxonomy,
            finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "x", expirationLeadDays: 30),
            index: index, duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
        await #expect(throws: (any Error).self) {
            try await actions.refile(entry, facets: DocumentFacets(description: "Corrected"), folder: "Legal")
        }
        #expect(try Data(contentsOf: source) == original)
        #expect((FileManager.default.subpaths(atPath: settings.outboxFolder.path) ?? []).filter { $0.hasSuffix(".pdf") } == ["Medical/old.pdf"])
    }

    @Test func failureAfterIndexCommitReturnsSuccessWithRecoveryWarning() throws {
        let source = try scan(), part = try output("filed.pdf")
        let transaction = FilingTransaction(settings: settings, index: index, checkpoint: {
            if case .indexed = $0 { throw FilingTransaction.Failure("Simulated cleanup failure") }
        })
        let result = try transaction.execute(source: source, outputs: [part], deleteSidecars: true)
        #expect(result.entries.count == 1 && result.warnings.count == 1)
        #expect(index.load().count == 1)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try FilingTransaction(settings: settings, index: index).recover() == 1)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(index.load().count == 1)
    }

    @Test func batchIndexFailureDoesNotReplaceExistingBytes() throws {
        try PrivateFile.write(Data("Existing index\n".utf8), to: index.url)
        let before = try Data(contentsOf: index.url)
        let part = try output("one.pdf")
        var invalid = part.entry
        invalid.confidence = .nan // Encoding must fail before any index mutation.
        #expect(throws: (any Error).self) { try index.append([part.entry, invalid]) }
        #expect(try Data(contentsOf: index.url) == before)
    }
}
