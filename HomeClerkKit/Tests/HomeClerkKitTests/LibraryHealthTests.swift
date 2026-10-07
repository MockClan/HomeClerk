import Foundation
import Testing
@testable import HomeClerkKit

struct LibraryHealthTests {
    let temp = TempFolder()
    var settings: HomeClerkSettings { HomeClerkSettings(basePath: temp.url) }
    var index: DocumentIndex { DocumentIndex(url: temp.url.appendingPathComponent(DocumentIndex.fileName)) }
    func pdf(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: settings.outboxFolder, withIntermediateDirectories: true)
        let file = settings.outboxFolder.appendingPathComponent(name)
        try TestPDF.make(file, pages: ["Synthetic archive document"])
        return file
    }
    func entry(_ file: URL, id: String = UUID().uuidString) -> DocumentIndex.Entry {
        .init(documentID: id, path: file.path, source: "scan.pdf", pages: [1, 1], model: "test", confidence: 1,
              summary: "", facets: DocumentFacets(vendor: "Example"))
    }
    var duplicates: DuplicateDetector { DuplicateDetector(duplicatesFolder: settings.duplicatesFolder) }
    func report() -> LibraryHealth.Report { LibraryHealth.scan(settings: settings, index: index) }

    /// Repair All: issues found by one scan stay valid after the others are repaired, so a batch
    /// works item by item, and undoing each in reverse restores the start.
    @Test func aBatchOfLikeRepairsAppliesAndUndoesInTurn() throws {
        for name in ["a.pdf", "b.pdf", "c.pdf"] { _ = try pdf(name) }
        let found = report().issues.filter { $0.kind == .unindexed }
        #expect(found.count == 3)
        var undos: [LibraryHealth.MetadataUndo] = []
        for issue in found {
            if let undo = try LibraryHealth.repair(issue, settings: settings, index: index, duplicates: duplicates).undo { undos.append(undo) }
        }
        #expect(report().issues.filter { $0.kind == .unindexed }.isEmpty)
        for undo in undos.reversed() { try LibraryHealth.undo(undo, settings: settings, index: index) }
        #expect(report().issues.filter { $0.kind == .unindexed }.count == 3)
    }

    /// Sync with Folders: records whose PDF is gone are removed and unrecorded PDFs added in one
    /// pass, the Library then matches the folders, and undoing in reverse puts it all back.
    @Test func syncWithFoldersRemovesAndAddsThenUndoes() throws {
        let gone = try pdf("gone.pdf")
        try index.append(entry(gone))
        try FileManager.default.removeItem(at: gone)
        for name in ["new-a.pdf", "new-b.pdf"] { _ = try pdf(name) }
        let issues = report().issues.filter { [.missing, .unindexed].contains($0.kind) }
        #expect(issues.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.missing, .unindexed, .unindexed])
        var undos: [LibraryHealth.MetadataUndo] = []
        for issue in issues {
            if let undo = try LibraryHealth.repair(issue, settings: settings, index: index, duplicates: duplicates).undo { undos.append(undo) }
        }
        #expect(report().issues.isEmpty)
        #expect(Set(DocumentLibrary.load(index).documents.map { ($0.path as NSString).lastPathComponent }) == ["new-a.pdf", "new-b.pdf"])
        for undo in undos.reversed() { try LibraryHealth.undo(undo, settings: settings, index: index) }
        #expect(report().issues.filter { [.missing, .unindexed].contains($0.kind) }.count == 3)
    }

    @Test func scanDoesNotCreateArchiveStoresAndAddUndoPreservesPDFBytes() throws {
        let file = try pdf("imported.pdf")
        let bytes = try Data(contentsOf: file)
        let issue = try #require(report().issues.first { $0.kind == .unindexed })
        #expect(!FileManager.default.fileExists(atPath: index.url.path))
        #expect(!FileManager.default.fileExists(atPath: settings.duplicatesFolder.path))
        let result = try LibraryHealth.repair(issue, settings: settings, index: index, duplicates: duplicates)
        let current = try #require(DocumentLibrary.load(index).documents.first)
        #expect(current.confidence == 0 && current.facets == DocumentFacets())
        #expect(try Data(contentsOf: file) == bytes)
        try LibraryHealth.undo(try #require(result.undo), settings: settings, index: index)
        #expect(DocumentLibrary.load(index).documents.isEmpty)
        #expect(try Data(contentsOf: file) == bytes)
        let restored = try #require(report().issues.first { $0.kind == .unindexed })
        _ = try LibraryHealth.repair(restored, settings: settings, index: index, duplicates: duplicates)
        #expect(DocumentLibrary.load(index).documents.first?.documentID == current.documentID)
    }

    @Test func hideMissingIsUndoableAndRefusesAFileRestoredSincePreview() throws {
        let file = try pdf("missing.pdf")
        let original = entry(file)
        try index.append(original)
        try FileManager.default.removeItem(at: file)
        let issue = try #require(report().issues.first { $0.kind == .missing })
        try TestPDF.make(file, pages: ["Restored after preview"])
        #expect(throws: LibraryHealth.Changed.self) { try LibraryHealth.repair(issue, settings: settings, index: index, duplicates: duplicates) }
        #expect(try index.loadValidated().last?.removed == false)
        try FileManager.default.removeItem(at: file)
        let result = try LibraryHealth.repair(issue, settings: settings, index: index, duplicates: duplicates)
        #expect(!report().issues.contains { $0.kind == .missing })
        try LibraryHealth.undo(try #require(result.undo), settings: settings, index: index)
        #expect(report().issues.contains { $0.kind == .missing })
    }

    @Test func renameHistoryAndReturnToReviewAreNotMissingDocuments() async throws {
        let file = try pdf("before.pdf")
        let original = entry(file)
        try index.append(original)
        let detector = duplicates
        let actions = ReviewActions(settings: settings, taxonomy: TestData.taxonomy,
            finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "test", expirationLeadDays: 30),
            index: index, duplicates: detector)
        var corrected = original.facets; corrected.vendor = "Corrected"
        let result = try await actions.refile(original, facets: corrected, folder: "Legal")
        #expect(!report().issues.contains { $0.kind == .missing || $0.title.contains("multiple paths") })
        _ = try actions.returnToReview(result.after)
        #expect(!report().issues.contains { $0.kind == .missing })
    }

    @Test func malformedIndexStopsInspectionAndCannotBeTreatedAsEmpty() throws {
        let file = try pdf("kept.pdf")
        try index.append(entry(file))
        var bytes = try Data(contentsOf: index.url); bytes.append(Data("{incomplete\n".utf8))
        try PrivateFile.write(bytes, to: index.url)
        let found = report()
        #expect(found.issues.count == 1 && found.issues.first?.kind == .unreadable)
        #expect(found.issues.first?.preview == nil)
        #expect(throws: (any Error).self) { try index.loadValidated() }
        #expect(try Data(contentsOf: index.url) == bytes)
    }

    @Test func staleDuplicateRepairPreservesValidAndOriginalScanFingerprints() throws {
        let file = try pdf("present.pdf")
        try index.append(entry(file))
        let detector = duplicates
        detector.register(ocrText: "", sha256: "original", facets: nil, label: file.lastPathComponent)
        detector.register(ocrText: "", sha256: "processed", facets: nil, label: file.lastPathComponent)
        detector.register(ocrText: "", sha256: "missing", facets: nil, label: "gone.pdf")
        let issue = try #require(report().issues.first { $0.kind == .staleDuplicate })
        _ = try LibraryHealth.repair(issue, settings: settings, index: index, duplicates: detector)
        #expect(detector.exactDuplicate(sha256: "missing") == nil)
        #expect(detector.exactDuplicate(sha256: "original") == file.lastPathComponent)
        #expect(detector.exactDuplicate(sha256: "processed") == file.lastPathComponent)
        #expect(try DuplicateDetector.recordedLabels(in: settings.duplicatesFolder).count == 2)
        let corrupt = Data("not JSON".utf8)
        let store = settings.duplicatesFolder.appendingPathComponent(DuplicateDetector.indexFileName)
        try PrivateFile.write(corrupt, to: store)
        #expect(report().issues.contains { $0.kind == .unreadable && $0.path == store.path })
        #expect(try Data(contentsOf: store) == corrupt)
    }

    @Test func symlinksAndOutsideIndexPathsHaveNoAutomaticRepair() throws {
        let file = try pdf("safe.pdf")
        let link = settings.outboxFolder.appendingPathComponent("linked.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let outside = try temp.file("outside.pdf")
        try index.append(entry(outside))
        let found = report()
        #expect(found.issues.contains { $0.kind == .unsafe && $0.path == link.path && $0.preview == nil })
        #expect(found.issues.contains { $0.kind == .unsafe && $0.path == outside.path && $0.preview == nil })
    }

    @Test func undoRefusesLaterMetadataAndInvalidPDFImportIsPreserved() throws {
        let file = try pdf("imported.pdf")
        let issue = try #require(report().issues.first { $0.kind == .unindexed })
        let result = try LibraryHealth.repair(issue, settings: settings, index: index, duplicates: duplicates)
        var edited = try #require(index.loadValidated().last); edited.facets.vendor = "Later correction"
        try index.append(edited)
        #expect(throws: LibraryHealth.Changed.self) { try LibraryHealth.undo(try #require(result.undo), settings: settings, index: index) }
        let invalid = settings.outboxFolder.appendingPathComponent("invalid.pdf")
        let bytes = Data("not a PDF".utf8); try bytes.write(to: invalid)
        let bad = try #require(report().issues.first { $0.kind == .unindexed && $0.path == invalid.path })
        #expect(throws: (any Error).self) { try LibraryHealth.repair(bad, settings: settings, index: index, duplicates: duplicates) }
        #expect(try Data(contentsOf: invalid) == bytes)
    }

    @Test func selectedRecoveryPreservesOtherJournalsAndBlocksPrematureMetadataRepair() throws {
        try FileManager.default.createDirectory(at: settings.inboxFolder, withIntermediateDirectories: true)
        let imported = try pdf("unindexed.pdf")
        let unindexed = try #require(report().issues.first { $0.path == imported.path })
        for name in ["one", "two"] {
            let scan = settings.inboxFolder.appendingPathComponent(name + ".pdf")
            try TestPDF.make(scan, pages: [name])
            let output = settings.outboxFolder.appendingPathComponent(name + ".pdf")
            var transaction = FilingTransaction(settings: settings, index: index)
            transaction.checkpoint = { point in if case .placed = point { throw FilingTransaction.Interrupted() } }
            #expect(throws: FilingTransaction.Interrupted.self) {
                try transaction.execute(source: scan, outputs: [.init(destination: output, entry: entry(output))])
            }
        }
        let pending = report().issues.filter { $0.kind == .pendingOperation }
        #expect(pending.count == 2)
        #expect(throws: (any Error).self) { try LibraryHealth.repair(unindexed, settings: settings, index: index, duplicates: duplicates) }
        let chosen = try #require(pending.first)
        _ = try LibraryHealth.repair(chosen, settings: settings, index: index, duplicates: duplicates)
        #expect(report().issues.filter { $0.kind == .pendingOperation }.count == 1)
        #expect(FileManager.default.fileExists(atPath: settings.inboxFolder.appendingPathComponent("one.pdf").path))
        #expect(FileManager.default.fileExists(atPath: settings.inboxFolder.appendingPathComponent("two.pdf").path))
        #expect(FileManager.default.fileExists(atPath: imported.path))
    }

    @Test func unreadableManagedFolderAndOrphanedFinishingHistoryAreVisible() throws {
        _ = try pdf("unindexed.pdf")
        let repairs = FinishingIssues(folder: temp.url)
        try repairs.update(documentID: "orphan", path: settings.outboxFolder.appendingPathComponent("lost.pdf").path,
            attempted: [.tags], failures: [.init(step: .tags, detail: "Synthetic tag failure")])
        let orphan = try #require(report().issues.first { $0.kind == .finishing })
        #expect(orphan.entry == nil && orphan.preview == nil && orphan.detail.contains("Restore"))
        try Data("not a folder".utf8).write(to: settings.reviewFolder)
        #expect(report().issues.first?.kind == .unsafe)
        #expect(report().issues.allSatisfy { $0.preview == nil })
    }

    @Test func changedSourceRecoveryRefusesDeletionAndPreservesEvidence() throws {
        _ = try pdf("present.pdf")
        try FileManager.default.createDirectory(at: settings.inboxFolder, withIntermediateDirectories: true)
        let scan = settings.inboxFolder.appendingPathComponent("scan.pdf")
        try TestPDF.make(scan, pages: ["Original source"])
        let output = settings.outboxFolder.appendingPathComponent("output.pdf")
        var transaction = FilingTransaction(settings: settings, index: index)
        transaction.checkpoint = { point in if case .placed = point { throw FilingTransaction.Interrupted() } }
        #expect(throws: FilingTransaction.Interrupted.self) {
            try transaction.execute(source: scan, outputs: [.init(destination: output, entry: entry(output))])
        }
        try TestPDF.make(scan, pages: ["Changed source"])
        let sourceBytes = try Data(contentsOf: scan), outputBytes = try Data(contentsOf: output)
        let issue = try #require(report().issues.first { $0.kind == .pendingOperation })
        #expect(throws: (any Error).self) { try LibraryHealth.repair(issue, settings: settings, index: index) }
        #expect(try Data(contentsOf: scan) == sourceBytes && Data(contentsOf: output) == outputBytes)
        #expect(FileManager.default.fileExists(atPath: issue.path))
    }
}
