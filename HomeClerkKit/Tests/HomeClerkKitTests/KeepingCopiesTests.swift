import Foundation
import PDFKit
import Testing
@testable import HomeClerkKit

/// Choosing the better of two copies. Fictional documents; nothing here comes from real ones.
@Suite struct KeepingCopiesTests {
    let temp = TempFolder()
    var settings: HomeClerkSettings { HomeClerkSettings(values: ["basepath": .string(temp.url.path)]) }
    var index: DocumentIndex { DocumentIndex(url: temp.url.appendingPathComponent(DocumentIndex.fileName)) }
    var actions: ReviewActions {
        ReviewActions(settings: settings, taxonomy: TestData.taxonomy,
                      finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "x",
                                         expirationLeadDays: 30),
                      index: index, duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
    }
    static let facets = DocumentFacets(documentType: "Bill", area: "Utilities", vendor: "Acme_Power", description: "Electric_Bill",
                                       documentDate: "2026-02-03", amount: Decimal(string: "88.12"))

    /// Files a copy under the name the rules give it, with `suffix` ("_2") as HomeClerk adds for a taken name.
    func filed(_ text: String, suffix: String = "", source: String) throws -> DocumentIndex.Entry {
        let (folder, name) = actions.destination(Self.facets)
        let stem = (name as NSString).deletingPathExtension
        let url = settings.outboxFolder.appendingPathComponent(folder).appendingPathComponent(stem + suffix + ".pdf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TestPDF.make(url, pages: [text])
        let entry = DocumentIndex.Entry(path: url.path, source: source, pages: [1, 1], model: "m", confidence: 0.9,
                                        summary: "", facets: Self.facets)
        try index.append(entry)
        return entry
    }

    @Test func keepingTheSecondCopyGivesItThePlainNameAndUndoPutsBothBack() async throws {
        let first = try filed("ACME POWER faint scan", source: "a.pdf")
        let second = try filed("ACME POWER clear scan", suffix: "_2", source: "b.pdf")
        let kept = try await actions.keep(second, removing: first)
        #expect(kept.kept.path == first.path)   // the plain name, now free
        #expect(PDFDocument(url: URL(fileURLWithPath: first.path))?.string?.contains("clear scan") == true)
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(DocumentLibrary.load(index).documents.map(\.path) == [first.path])

        try await actions.undo(kept)
        #expect(PDFDocument(url: URL(fileURLWithPath: first.path))?.string?.contains("faint scan") == true)
        #expect(PDFDocument(url: URL(fileURLWithPath: second.path))?.string?.contains("clear scan") == true)
        #expect(Set(DocumentLibrary.load(index).documents.map(\.path)) == [first.path, second.path])
    }

    @Test func keepingTheFirstCopyLeavesItsName() async throws {
        let first = try filed("ACME POWER clear scan", source: "a.pdf")
        let second = try filed("ACME POWER faint scan", suffix: "_2", source: "b.pdf")
        let kept = try await actions.keep(first, removing: second)
        #expect(kept.kept.path == first.path)
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test func aBetterScanSetAsideTakesTheFiledCopysPlace() async throws {
        let filed = try filed("ACME POWER faint scan", source: "a.pdf")
        try FileManager.default.createDirectory(at: settings.duplicatesFolder, withIntermediateDirectories: true)
        let scan = settings.duplicatesFolder.appendingPathComponent("rescan.pdf")
        try TestPDF.make(scan, pages: ["ACME POWER clear scan"])
        try "Duplicate of: x".write(to: ReviewProposal.reasonURL(for: scan), atomically: true, encoding: .utf8)
        let item = DuplicateItem(url: scan, original: URL(fileURLWithPath: filed.path), originalLabel: "x", why: "")

        let replaced = try await actions.keepScanInstead(item)
        #expect(PDFDocument(url: URL(fileURLWithPath: filed.path))?.string?.contains("clear scan") == true)
        // The filed copy it replaced went to the Trash, not overwritten
        #expect(PDFDocument(url: replaced.replaced.inTrash)?.string?.contains("faint scan") == true)
        #expect(!FileManager.default.fileExists(atPath: scan.path))
        #expect(!FileManager.default.fileExists(atPath: ReviewProposal.reasonURL(for: scan).path))
        #expect(DocumentLibrary.load(index).documents.map(\.path) == [filed.path])

        try actions.undo(replaced)
        #expect(PDFDocument(url: URL(fileURLWithPath: filed.path))?.string?.contains("faint scan") == true)
        #expect(FileManager.default.fileExists(atPath: scan.path))
        #expect(FileManager.default.fileExists(atPath: ReviewProposal.reasonURL(for: scan).path))
    }

    @Test func aWholePileSetAsideCantTakeOneDocumentsPlace() async throws {
        let filed = try filed("ACME POWER", source: "a.pdf")
        try FileManager.default.createDirectory(at: settings.duplicatesFolder, withIntermediateDirectories: true)
        let pile = settings.duplicatesFolder.appendingPathComponent("pile.pdf")
        try TestPDF.make(pile, pages: ["ACME POWER", "CORNER HARDWARE"])
        let item = DuplicateItem(url: pile, original: URL(fileURLWithPath: filed.path), originalLabel: "x",
                                 why: DuplicateItem.wholePileReason, wholePile: true)
        await #expect(throws: ReviewActions.LibraryActionError.self) { _ = try await actions.keepScanInstead(item) }
        #expect(PDFDocument(url: URL(fileURLWithPath: filed.path))?.pageCount == 1)
    }

    @Test func aStaleListOrAnUnusualNameIsLeftAlone() async throws {
        let first = try filed("ACME POWER first", source: "a.pdf")
        var stale = try filed("ACME POWER second", suffix: "_2", source: "b.pdf")
        stale.documentID = "an-older-document"
        await #expect(throws: ReviewActions.LibraryActionError.self) { _ = try await actions.keep(first, removing: stale) }
        #expect(FileManager.default.fileExists(atPath: stale.path))

        // "_1099" is part of the name the details give, not a number HomeClerk added: no rename
        let form = URL(fileURLWithPath: first.path).deletingLastPathComponent().appendingPathComponent("Form_1099.pdf")
        try TestPDF.make(form, pages: ["ACME POWER form"])
        let entry = DocumentIndex.Entry(path: form.path, source: "c.pdf", pages: [1, 1], model: "m", confidence: 0.9,
                                        summary: "", facets: Self.facets)
        try index.append(entry)
        let kept = try await actions.keep(entry, removing: first)
        #expect(kept.kept.path == form.path)
    }
}
