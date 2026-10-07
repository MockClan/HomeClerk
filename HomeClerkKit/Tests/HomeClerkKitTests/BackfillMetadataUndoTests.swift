import Foundation
import Testing
@testable import HomeClerkKit

@Suite struct BackfillMetadataUndoTests {
    let temp = TempFolder()
    var settings: HomeClerkSettings { HomeClerkSettings(values: ["basepath": .string(temp.url.path)]) }
    var index: DocumentIndex { DocumentIndex(url: settings.basePath.appendingPathComponent(DocumentIndex.fileName)) }
    let text = Array(repeating: "Fictional household statement, invoice, and account details.", count: 10).joined(separator: "\n")
    var original: URL { settings.outboxFolder.appendingPathComponent("Old/bill.pdf") }
    var oldFacets: DocumentFacets { DocumentFacets(vendor: "Old_Vendor", documentDate: "2026-01-01", amount: 90, person: "Pat_Example") }
    var finisher: Finisher { Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "x", expirationLeadDays: 30) }

    func apply(_ action: BackfillEntry.Action, indexed: Bool = true) async throws -> (BackfillApplier.Result, DocumentIndex.Entry?, DuplicateDetector) {
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TestPDF.make(original, pages: [text])
        var old: DocumentIndex.Entry?
        if indexed {
            var entry = DocumentIndex.Entry(filedAt: Date(timeIntervalSince1970: 1_700_000_000), path: original.path,
                source: "original-scan.pdf", pages: [1, 1], model: "original model", confidence: 0.82,
                summary: "Original summary", facets: oldFacets)
            entry.corrected = true
            try index.append(entry)
            old = index.load().last
        }
        let duplicates = DuplicateDetector(duplicatesFolder: settings.duplicatesFolder)
        if indexed {
            duplicates.register(ocrText: text, sha256: "original-inbox-hash", facets: oldFacets, label: "Old/bill.pdf")
        }
        var entry = BackfillEntry(path: "Old/bill.pdf", sha256: BackfillApplier.sha256(try Data(contentsOf: original)), handCorrected: false)
        entry.action = action; entry.apply = true; entry.proposedFolder = "New"; entry.proposedName = "renamed.pdf"
        entry.facets = DocumentFacets(vendor: "New_Vendor", documentDate: "2030-02-02", amount: 150, person: "Pat_Example")
        entry.model = "new model"; entry.confidence = 0.99; entry.summary = "New summary"
        let result = try await BackfillApplier(finisher: finisher, index: index, duplicates: duplicates).apply(
            BackfillPlan(createdAt: .now, organizedFolder: settings.outboxFolder.path, model: "test", entries: [entry]),
            undoFolder: settings.basePath.appendingPathComponent("backfill"))
        #expect(result.problems.isEmpty)
        return (result, old, duplicates)
    }

    @Test(arguments: [BackfillEntry.Action.keep, .move, .rename])
    func undoRestoresAllMetadataAndPriorDuplicateMatches(action: BackfillEntry.Action) async throws {
        let (result, previous, duplicates) = try await apply(action)
        let old = try #require(previous)
        let changed = try #require(DocumentLibrary.load(index).documents.first)
        #expect(changed.facets.vendor == "New_Vendor" && changed.corrected)
        #expect(duplicates.exactDuplicate(sha256: "original-inbox-hash") == nil)
        let undone = try BackfillApplier.undo(result.undoLog, organized: settings.outboxFolder, index: index, duplicates: duplicates)
        #expect(undone.restored == 1 && undone.problems.isEmpty)
        var restored = try #require(DocumentLibrary.load(index).documents.first)
        restored.operationID = old.operationID
        #expect(restored == old)
        #expect(duplicates.exactDuplicate(sha256: "original-inbox-hash") == "Old/bill.pdf")
        #expect(duplicates.nearDuplicate(ocrText: text, facets: oldFacets) == "Old/bill.pdf")
        #expect(duplicates.nearDuplicate(ocrText: text, facets: changed.facets) == nil)
        let reloaded = DuplicateDetector(duplicatesFolder: settings.duplicatesFolder)
        #expect(reloaded.exactDuplicate(sha256: "original-inbox-hash") == "Old/bill.pdf")
        let again = try BackfillApplier.undo(result.undoLog, organized: settings.outboxFolder, index: index, duplicates: duplicates)
        #expect(again.restored == 0 && again.problems.isEmpty)
    }

    @Test(arguments: [BackfillEntry.Action.keep, .move])
    func undoReturnsUnindexedFileToItsOriginalState(action: BackfillEntry.Action) async throws {
        let (result, _, duplicates) = try await apply(action, indexed: false)
        #expect(DocumentLibrary.load(index).documents.count == 1)
        let current = try #require(DocumentLibrary.load(index).documents.first)
        let hash = BackfillApplier.sha256(try Data(contentsOf: URL(fileURLWithPath: current.path)))
        let undone = try BackfillApplier.undo(result.undoLog, organized: settings.outboxFolder, index: index, duplicates: duplicates)
        #expect(undone.restored == 1 && undone.problems.isEmpty)
        #expect(DocumentLibrary.load(index).documents.isEmpty)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(duplicates.exactDuplicate(sha256: hash) == nil)
    }

    @Test func laterMetadataEditIsPreservedEvenWhenBytesAreUnchanged() async throws {
        let (result, _, duplicates) = try await apply(.keep)
        var edited = try #require(DocumentLibrary.load(index).documents.first)
        edited.facets.vendor = "User_Correction"
        try index.append(edited)
        let undone = try BackfillApplier.undo(result.undoLog, organized: settings.outboxFolder, index: index, duplicates: duplicates)
        #expect(undone.restored == 0 && undone.problems.contains { $0.contains("Metadata changed") })
        #expect(DocumentLibrary.load(index).documents.first?.facets.vendor == "User_Correction")
    }

    @Test func failedMetadataCommitKeepsFileAndCanBeRetried() async throws {
        let (result, _, duplicates) = try await apply(.move)
        let after = try #require(DocumentLibrary.load(index).documents.first)
        let savedIndex = try Data(contentsOf: index.url)
        try FileManager.default.removeItem(at: index.url)
        try FileManager.default.createDirectory(at: index.url, withIntermediateDirectories: true)
        let failed = try BackfillApplier.undo(result.undoLog, organized: settings.outboxFolder, index: index, duplicates: duplicates)
        #expect(failed.restored == 0 && !failed.problems.isEmpty)
        #expect(FileManager.default.fileExists(atPath: after.path))
        #expect(!FileManager.default.fileExists(atPath: original.path))
        try FileManager.default.removeItem(at: index.url)
        try PrivateFile.write(savedIndex, to: index.url)
        let retried = try BackfillApplier.undo(result.undoLog, organized: settings.outboxFolder, index: index, duplicates: duplicates)
        #expect(retried.restored == 1 && retried.problems.isEmpty)
    }

    @Test func indexSnapshotDatesStayStableAcrossLogRewrites() throws {
        let entry = DocumentIndex.Entry(filedAt: Date(timeIntervalSince1970: 1_700_000_000.007),
            path: original.path, source: "scan.pdf", pages: [], model: "test", confidence: 1, summary: "", facets: oldFacets)
        let first = try JSONDecoder().decode(DocumentIndex.Entry.self, from: JSONEncoder().encode(entry))
        var snapshot = first
        for _ in 0..<5 {
            snapshot = try JSONDecoder().decode(DocumentIndex.Entry.self, from: JSONEncoder().encode(snapshot))
            #expect(snapshot == first)
        }
    }

    @Test func duplicateSaveFailureLeavesRetryableRestoration() async throws {
        let (result, _, duplicates) = try await apply(.move)
        let duplicateFile = settings.duplicatesFolder.appendingPathComponent(DuplicateDetector.indexFileName)
        try FileManager.default.removeItem(at: duplicateFile)
        try FileManager.default.createDirectory(at: duplicateFile, withIntermediateDirectories: true)
        let first = try BackfillApplier.undo(result.undoLog, organized: settings.outboxFolder, index: index, duplicates: duplicates)
        #expect(first.restored == 1 && first.problems.contains { $0.contains("duplicate records need retry") })
        #expect(DocumentLibrary.load(index).documents.first?.facets.vendor == "Old_Vendor")
        try FileManager.default.removeItem(at: duplicateFile)
        let retry = try BackfillApplier.undo(result.undoLog, organized: settings.outboxFolder, index: index, duplicates: duplicates)
        #expect(retry.restored == 0 && retry.problems.isEmpty)
        #expect(duplicates.exactDuplicate(sha256: "original-inbox-hash") == "Old/bill.pdf")
    }

    @Test func interruptedUndoCommitRecoversAndFinishesDuplicateRestoration() async throws {
        let (result, previous, duplicates) = try await apply(.move)
        let before = try #require(previous)
        let after = try #require(DocumentLibrary.load(index).documents.first)
        var records = try JSONDecoder().decode([BackfillApplier.UndoMove].self, from: Data(contentsOf: result.undoLog))
        let undoID = UUID().uuidString
        records[0].undoOperationID = undoID
        try PrivateFile.writeJSON(records, to: result.undoLog)
        let transaction = FilingTransaction(settings: settings, index: index, checkpoint: {
            if case .indexed = $0 { throw FilingTransaction.Interrupted() }
        })
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(throws: FilingTransaction.Interrupted.self) {
            try transaction.execute(source: URL(fileURLWithPath: after.path), outputs: [.init(destination: original, entry: before)], operationID: undoID)
        }
        let retry = try BackfillApplier.undo(result.undoLog, organized: settings.outboxFolder, index: index, duplicates: duplicates)
        #expect(retry.restored == 0 && retry.problems.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: after.path))
        #expect(DocumentLibrary.load(index).documents.first?.facets.vendor == "Old_Vendor")
        #expect(duplicates.exactDuplicate(sha256: "original-inbox-hash") == "Old/bill.pdf")
    }

    @Test func malformedMetadataSnapshotRefusesWholeLog() async throws {
        let (result, _, duplicates) = try await apply(.move)
        var records = try JSONDecoder().decode([BackfillApplier.UndoMove].self, from: Data(contentsOf: result.undoLog))
        records[0].before?.path = temp.url.appendingPathComponent("outside.pdf").path
        try PrivateFile.writeJSON(records, to: result.undoLog)
        #expect(throws: BackfillApplier.InvalidUndoLog.self) {
            try BackfillApplier.undo(result.undoLog, organized: settings.outboxFolder, index: index, duplicates: duplicates)
        }
        #expect(DocumentLibrary.load(index).documents.first?.facets.vendor == "New_Vendor")
    }

    @Test func preparedRecordRecoversCommittedMetadataOrSkipsUncommittedOperation() async throws {
        let (result, _, duplicates) = try await apply(.keep)
        var records = try JSONDecoder().decode([BackfillApplier.UndoMove].self, from: Data(contentsOf: result.undoLog))
        records[0].status = .prepared // Crash after committing, before recording completion.
        try PrivateFile.writeJSON(records, to: result.undoLog)
        let undone = try BackfillApplier.undo(result.undoLog, organized: settings.outboxFolder, index: index, duplicates: duplicates)
        #expect(undone.problems.isEmpty)
        #expect(undone.restored == 1)
        var uncommitted = records
        uncommitted[0].after?.operationID = UUID().uuidString
        try PrivateFile.writeJSON(uncommitted, to: result.undoLog)
        let skipped = try BackfillApplier.undo(result.undoLog, organized: settings.outboxFolder, index: index, duplicates: duplicates)
        #expect(skipped.restored == 0 && skipped.problems.isEmpty)
        #expect(DocumentLibrary.load(index).documents.first?.facets.vendor == "Old_Vendor")
    }
}
