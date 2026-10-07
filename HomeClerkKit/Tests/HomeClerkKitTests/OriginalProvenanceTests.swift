import Foundation
import Testing
@testable import HomeClerkKit

@Suite struct OriginalProvenanceTests {
    let temp = TempFolder()
    var settings: HomeClerkSettings { HomeClerkSettings(values: ["basepath": .string(temp.url.path)]) }
    var index: DocumentIndex { DocumentIndex(url: settings.basePath.appendingPathComponent("index.jsonl")) }
    var actions: ReviewActions {
        ReviewActions(settings: settings, taxonomy: TestData.taxonomy,
            finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "x", expirationLeadDays: 30),
            index: index, duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
    }
    func scan(pages: [String] = ["Fictional scan"]) throws -> URL {
        try FileManager.default.createDirectory(at: settings.reviewFolder, withIntermediateDirectories: true)
        let url = settings.reviewFolder.appendingPathComponent("scan1.pdf")
        try TestPDF.make(url, pages: pages)
        try Originals.preserve(url, in: settings.originalsFolder)
        return url
    }
    func age(_ original: URL, days: Double = 200) throws {
        var record = try #require(PrivateFile.readJSON(Originals.CopyRecord.self, from: Originals.recordURL(for: original)))
        record.copiedAt = Date().addingTimeInterval(-days * 86_400)
        try PrivateFile.writeJSON(record, to: Originals.recordURL(for: original))
    }
    var original: URL { settings.originalsFolder.appendingPathComponent("scan1.pdf") }
    func candidates(_ entries: [DocumentIndex.Entry]? = nil) -> [ClearableOriginal] {
        Originals.clearable(in: settings.originalsFolder, documents: entries ?? DocumentLibrary.load(index).documents)
    }

    @Test func committedSingleFilingHasPrivateProofAndSurvivesRename() async throws {
        let source = try scan()
        try age(original)
        #expect(candidates().isEmpty)
        let filing = try await actions.fileInFolder(source, folder: "Medical", document: nil, analysis: nil)
        let record = try #require(PrivateFile.readJSON(Originals.CopyRecord.self, from: Originals.recordURL(for: original)))
        #expect(record.proof?.outputs.first?.documentID == index.load().first?.documentID)
        #expect(candidates().map { $0.url.resolvingSymlinksInPath().path } == [original.resolvingSymlinksInPath().path])
        #expect((try FileManager.default.attributesOfItem(atPath: Originals.recordURL(for: original).path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: original.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let entry = try #require(DocumentLibrary.load(index).documents.first)
        _ = try await actions.refile(entry, facets: DocumentFacets(description: "Corrected"), folder: "Legal")
        #expect(!FileManager.default.fileExists(atPath: filing.destination.path))
        #expect(candidates().map { $0.url.resolvingSymlinksInPath().path } == [original.resolvingSymlinksInPath().path])
    }

    @Test func reusedScannerNameDoesNotClearDifferentReviewScan() async throws {
        let source = try scan(pages: ["Successfully filed document"])
        try age(original)
        _ = try await actions.fileInFolder(source, folder: "Medical", document: nil, analysis: nil)
        _ = try scan(pages: ["Different document still waiting in Review"])
        let second = settings.originalsFolder.appendingPathComponent("scan1_2.pdf")
        try age(second)
        #expect(candidates().map { $0.url.resolvingSymlinksInPath().path } == [original.resolvingSymlinksInPath().path])
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test func splitRequiresEveryUnchangedOutput() async throws {
        let source = try scan(pages: ["Page one", "Page two", "Page three"])
        try age(original)
        let documents = [FacetDocument(firstPage: 1, lastPage: 1, facets: DocumentFacets(description: "First"), confidence: 1),
                         FacetDocument(firstPage: 2, lastPage: 3, facets: DocumentFacets(description: "Second"), confidence: 1)]
        let split = try await actions.fileSplit(source, documents: documents, analysis: nil)
        #expect(candidates().map { $0.url.resolvingSymlinksInPath().path } == [original.resolvingSymlinksInPath().path])
        let data = try Data(contentsOf: split.parts[1].destination)
        try FileManager.default.removeItem(at: split.parts[1].destination)
        #expect(candidates().isEmpty)
        try PrivateFile.write(data, to: split.parts[1].destination)
        #expect(candidates().map { $0.url.resolvingSymlinksInPath().path } == [original.resolvingSymlinksInPath().path])
        try TestPDF.make(split.parts[1].destination, pages: ["Replaced page", "Different contents"])
        #expect(candidates().isEmpty)
    }

    @Test func indexFailureOrUndoNeverOffersOriginal() async throws {
        let source = try scan()
        try age(original)
        try FileManager.default.createDirectory(at: index.url, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { try await actions.fileInFolder(source, folder: "Medical", document: nil, analysis: nil) }
        #expect(candidates().isEmpty)
        try FileManager.default.removeItem(at: index.url)
        let filing = try await actions.fileInFolder(source, folder: "Medical", document: nil, analysis: nil)
        #expect(candidates().map { $0.url.resolvingSymlinksInPath().path } == [original.resolvingSymlinksInPath().path])
        try actions.undo(filing)
        #expect(candidates().isEmpty)
    }

    @Test func changedOriginalMissingProofAndRecentCopyAreRetained() async throws {
        let source = try scan()
        _ = try await actions.fileInFolder(source, folder: "Medical", document: nil, analysis: nil)
        #expect(candidates().isEmpty) // Recent, despite complete filing.
        try age(original)
        #expect(candidates().count == 1)
        let bytes = try Data(contentsOf: original)
        try TestPDF.make(original, pages: ["Replacement original"])
        #expect(candidates().isEmpty)
        try PrivateFile.write(bytes, to: original)
        try FileManager.default.removeItem(at: Originals.recordURL(for: original))
        #expect(candidates().isEmpty)
    }

    @Test func malformedProofAndAmbiguousDocumentIDsAreRetained() async throws {
        let source = try scan()
        try age(original)
        _ = try await actions.fileInFolder(source, folder: "Medical", document: nil, analysis: nil)
        let entry = try #require(index.load().first)
        #expect(candidates([entry, entry]).isEmpty)
        var record = try #require(PrivateFile.readJSON(Originals.CopyRecord.self, from: Originals.recordURL(for: original)))
        record.proof?.outputs[0].pages = [2, 2] // Leaves page one uncovered.
        try PrivateFile.writeJSON(record, to: Originals.recordURL(for: original))
        #expect(candidates().isEmpty)
        try PrivateFile.write(Data("Unreadable proof".utf8), to: Originals.recordURL(for: original))
        #expect(candidates().isEmpty)
    }

    @Test func interruptedCommitConservativelyRetainsOriginalWithoutProof() throws {
        let source = try scan()
        try age(original)
        let destination = try FileOrganizer(outbox: settings.outboxFolder).destination(folder: "Medical", filename: "filed.pdf")
        let entry = DocumentIndex.Entry(path: destination.path, source: "scan1.pdf", pages: [], model: "", confidence: 1, summary: "", facets: DocumentFacets())
        let transaction = FilingTransaction(settings: settings, index: index, checkpoint: {
            if case .indexed = $0 { throw FilingTransaction.Interrupted() }
        })
        #expect(throws: FilingTransaction.Interrupted.self) { try transaction.execute(source: source, outputs: [.init(destination: destination, entry: entry)]) }
        #expect(try FilingTransaction(settings: settings, index: index).recover() == 1)
        #expect(candidates().isEmpty)
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test func finishingChangesAreHashedAfterCompletion() throws {
        let source = try scan()
        try age(original)
        let destination = try FileOrganizer(outbox: settings.outboxFolder).destination(folder: "Medical", filename: "filed.pdf")
        let entry = DocumentIndex.Entry(path: destination.path, source: "scan1.pdf", pages: [], model: "", confidence: 1, summary: "", facets: DocumentFacets())
        let result = try FilingTransaction(settings: settings, index: index).execute(source: source, outputs: [.init(destination: destination, entry: entry)])
        // Simulates a text-layer rewrite after commit; page count stays unchanged.
        try TestPDF.make(destination, pages: ["Fictional scan with a searchable text layer"])
        #expect(result.recordOriginalFiling(settings: settings).isEmpty)
        #expect(candidates().map { $0.url.resolvingSymlinksInPath().path } == [original.resolvingSymlinksInPath().path])
    }
}

@Suite struct OlderOriginalsTests {
    let temp = TempFolder()
    var settings: HomeClerkSettings { HomeClerkSettings(values: ["basepath": .string(temp.url.path)]) }
    let longAgo = Date().addingTimeInterval(-200 * 86_400)

    /// A copy as an earlier HomeClerk left it: no filing record, made `date`.
    func olderCopy(_ name: String, date: Date) throws -> URL {
        try FileManager.default.createDirectory(at: settings.originalsFolder, withIntermediateDirectories: true)
        let url = settings.originalsFolder.appendingPathComponent(name)
        try TestPDF.make(url, pages: ["Fictional scan"])
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: url.path)
        return url
    }

    func filed(from scan: String) throws -> DocumentIndex.Entry {
        let folder = settings.outboxFolder.appendingPathComponent("Utilities")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("\(UUID().uuidString).pdf")
        try TestPDF.make(path, pages: ["Fictional filed"])
        return DocumentIndex.Entry(path: path.path, source: scan, pages: [1, 1], model: "m", confidence: 0.9, summary: "",
                                   facets: DocumentFacets())
    }

    @Test func listsOldUnrecordedCopiesOfFiledScansOnly() throws {
        let filedCopy = try olderCopy("scan0042.pdf", date: longAgo)
        let suffixed = try olderCopy("scan0043_2.pdf", date: longAgo)
        _ = try olderCopy("never-filed.pdf", date: longAgo)
        _ = try olderCopy("scan0044.pdf", date: Date())                // too recent
        let waiting = try olderCopy("scan0045.pdf", date: longAgo)      // its scan is still in Review
        try FileManager.default.createDirectory(at: settings.reviewFolder, withIntermediateDirectories: true)
        try TestPDF.make(settings.reviewFolder.appendingPathComponent("scan0045.pdf"), pages: ["Fictional"])
        let documents = try ["scan0042.pdf", "scan0043.pdf", "scan0044.pdf", "scan0045.pdf"].map(filed)

        let older = Originals.olderCopies(in: settings.originalsFolder, documents: documents,
                                          pending: [settings.inboxFolder, settings.reviewFolder])
        #expect(Set(older.map(\.url.lastPathComponent)) == [filedCopy.lastPathComponent, suffixed.lastPathComponent])
        #expect(!older.contains { $0.url == waiting })
    }

    @Test func aMatchingFingerprintIsEvidenceToo() throws {
        let copy = try olderCopy("renamed-by-scanner.pdf", date: longAgo)
        let filedDoc = try filed(from: "backfill:Utilities/something-else.pdf")
        let duplicates = DuplicateDetector(duplicatesFolder: settings.duplicatesFolder)
        let label = String(filedDoc.path.dropFirst(settings.outboxFolder.path.count + 1))
        duplicates.register(ocrText: "Fictional scan", sha256: BackfillApplier.sha256(try Data(contentsOf: copy)), facets: nil, label: label)
        let older = Originals.olderCopies(in: settings.originalsFolder, documents: [filedDoc], pending: [], fingerprints: duplicates)
        #expect(older.map(\.url.lastPathComponent) == ["renamed-by-scanner.pdf"])
        // Without the fingerprint there's no evidence, so it's kept
        #expect(Originals.olderCopies(in: settings.originalsFolder, documents: [filedDoc], pending: []).isEmpty)
    }

    /// Scanners number each day's scans; one filed scan isn't evidence for the others that day.
    @Test func scannerCountersAreNotCollisionSuffixes() throws {
        #expect(Originals.scanName("Document_20300114_0001.pdf") == "document_20300114_0001.pdf")
        #expect(Originals.scanName("Document_20300114_0001_2.pdf") == "document_20300114_0001.pdf")
        let documents = [try filed(from: "Document_20300114_0001.pdf")]
        _ = try olderCopy("Document_20300114_0001.pdf", date: longAgo)
        _ = try olderCopy("Document_20300114_0002.pdf", date: longAgo)
        let older = Originals.olderCopies(in: settings.originalsFolder, documents: documents, pending: [])
        #expect(older.map(\.url.lastPathComponent) == ["Document_20300114_0001.pdf"])
    }

    @Test func copiesWithFilingRecordsAreNeverOlderCopies() throws {
        let documents = [try filed(from: "scan0050.pdf")]
        let copy = try olderCopy("scan0050.pdf", date: longAgo)
        try PrivateFile.writeJSON(["id": UUID().uuidString], to: Originals.recordURL(for: copy))
        #expect(Originals.olderCopies(in: settings.originalsFolder, documents: documents, pending: []).isEmpty)
    }
}
