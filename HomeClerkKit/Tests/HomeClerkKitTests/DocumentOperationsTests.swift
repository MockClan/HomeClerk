import Foundation
import Testing
@testable import HomeClerkKit

struct DocumentOperationsTests {
    actor Gate {
        var started = false
        var observer: CheckedContinuation<Void, Never>?
        var worker: CheckedContinuation<Void, Never>?
        func pause() async {
            if started { return }
            await withCheckedContinuation { continuation in
                worker = continuation
                started = true
                observer?.resume(); observer = nil
            }
        }
        func waitForStart() async {
            if started { return }
            await withCheckedContinuation { observer = $0 }
        }
        func open() { worker?.resume(); worker = nil }
    }

    @Test func filingHoldsItsDestinationWhileFinishingAwaits() async throws {
        let temp = TempFolder()
        let settings = HomeClerkSettings(basePath: temp.url)
        try FileManager.default.createDirectory(at: settings.reviewFolder, withIntermediateDirectories: true)
        let scan = settings.reviewFolder.appendingPathComponent("scan.pdf")
        try TestPDF.make(scan, pages: ["A bill awaiting reminders"])
        let index = DocumentIndex(url: temp.url.appendingPathComponent(DocumentIndex.fileName))
        let gate = Gate()
        var finisher = Finisher(makeSearchable: false, applyTags: false, createReminders: true,
            remindersList: "test", expirationLeadDays: 30)
        finisher.operations = .init(searchable: { _ in }, tags: { _, _ in },
            reminders: { _, _ in await gate.pause(); return [] })
        let actions = ReviewActions(settings: settings, taxonomy: TestData.taxonomy, finisher: finisher,
            index: index, duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
        let facets = DocumentFacets(documentType: "Bill", area: "Utilities", vendor: "Example",
            dueDate: "2099-12-31", amount: 10)
        let task = Task { try await actions.fileEdited(scan, facets: facets, folder: nil, analysis: nil, confidence: 1) }
        await gate.waitForStart()
        let entry = DocumentLibrary.load(index).documents.first
        var refused = false
        if let entry {
            do { _ = try await actions.refile(entry, facets: facets, folder: nil) }
            catch is DocumentOperations.Busy { refused = true }
            catch { Issue.record("Unexpected conflict error: \(error)") }
        }
        await gate.open()
        _ = try await task.value
        #expect(entry != nil && refused)
        let current = try #require(DocumentLibrary.load(index).documents.first)
        _ = try await actions.refile(current, facets: facets, folder: nil)
    }

    @Test func batchClaimsAreAtomicAndReleaseCannotClearANewOwner() throws {
        let temp = TempFolder()
        let a = temp.url.appendingPathComponent("a.pdf"), b = temp.url.appendingPathComponent("b.pdf")
        let first = try DocumentOperations.acquire([a])
        defer { first.release() }
        #expect(throws: DocumentOperations.Busy.self) { try DocumentOperations.acquire([b, a]) }
        let independent = try DocumentOperations.acquire([b])
        independent.release()
        first.release()
        let replacement = try DocumentOperations.acquire([a])
        defer { replacement.release() }
        first.release()
        #expect(throws: DocumentOperations.Busy.self) { try DocumentOperations.acquire([a]) }
    }

    @Test func aliasesCannotBypassAClaim() throws {
        let temp = TempFolder()
        let file = try temp.file("scan.pdf")
        let alias = temp.url.appendingPathComponent("alias.pdf")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        let lease = try DocumentOperations.acquire([file])
        defer { lease.release() }
        #expect(throws: DocumentOperations.Busy.self) { try DocumentOperations.acquire([alias]) }
    }

    @Test func busyRefileAndStaleEditsLeaveTheCurrentDocumentUntouched() async throws {
        let temp = TempFolder()
        var settings = HomeClerkSettings(basePath: temp.url)
        settings.applyFinderTags = false
        try FileManager.default.createDirectory(at: settings.outboxFolder, withIntermediateDirectories: true)
        let file = settings.outboxFolder.appendingPathComponent("original.pdf")
        try TestPDF.make(file, pages: ["Document remains intact"])
        let index = DocumentIndex(url: temp.url.appendingPathComponent(DocumentIndex.fileName))
        let entry = DocumentIndex.Entry(path: file.path, source: "scan.pdf", pages: [1, 1], model: "test",
            confidence: 1, summary: "", facets: .init(documentType: "Bill", area: "Utilities", vendor: "Example"))
        try index.append(entry)
        let actions = ReviewActions(settings: settings, taxonomy: TestData.taxonomy,
            finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false,
                remindersList: "test", expirationLeadDays: 30), index: index,
            duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
        let before = try Data(contentsOf: index.url)
        let lease = try DocumentOperations.acquire([file])
        do {
            _ = try await actions.refile(entry, facets: entry.facets, folder: nil)
            Issue.record("Overlapping refile was accepted")
        } catch is DocumentOperations.Busy { }
        lease.release()
        #expect(try Data(contentsOf: index.url) == before)
        #expect(FileManager.default.fileExists(atPath: file.path))
        var corrected = entry.facets
        corrected.vendor = "Corrected"
        let saved = try await actions.refile(entry, facets: corrected, folder: nil)
        let committed = try Data(contentsOf: index.url)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: saved.after.path))
        do {
            _ = try await actions.refile(entry, facets: entry.facets, folder: nil)
            Issue.record("Stale refile was accepted")
        } catch {
            #expect(error.localizedDescription.contains("changed since editing began"))
        }
        #expect(try Data(contentsOf: index.url) == committed)
        #expect(try Data(contentsOf: URL(fileURLWithPath: saved.after.path)) == bytes)
        #expect(DocumentLibrary.load(index).documents.first?.facets == corrected)
    }
}
