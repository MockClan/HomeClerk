import Foundation
import PDFKit
import Testing
@testable import HomeClerkKit

/// Filed documents that are pieces of one. Fictional documents; nothing here comes from real ones.
@Suite struct JoiningTests {
    let temp = TempFolder()
    var settings: HomeClerkSettings { HomeClerkSettings(values: ["basepath": .string(temp.url.path)]) }
    var index: DocumentIndex { DocumentIndex(url: temp.url.appendingPathComponent(DocumentIndex.fileName)) }
    var actions: ReviewActions {
        ReviewActions(settings: settings, taxonomy: TestData.taxonomy,
                      finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "x",
                                         expirationLeadDays: 30),
                      index: index, duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
    }

    static let program = DocumentFacets(documentType: "Record", area: "Medical", vendor: "Example_Clinic",
                                        documentDate: "2026-06-09", person: "Pat_Example")

    func filed(_ name: String, _ pages: [String], _ facets: DocumentFacets = program) throws -> DocumentIndex.Entry {
        let url = settings.outboxFolder.appendingPathComponent("Medical - Records/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TestPDF.make(url, pages: pages)
        let entry = DocumentIndex.Entry(path: url.path, source: "pile.pdf", pages: [1, pages.count], model: "m",
                                        confidence: 0.9, summary: "", facets: facets)
        try index.append(entry)
        return entry
    }

    @Test func halvesOfOneDocumentAreSuggestedInPageOrder() throws {
        // The second half was filed first, under the clinic's short name
        var short = Self.program
        short.vendor = "EC"
        let back = try filed("back.pdf", ["Stretches Page 3 of 4", "Page 4 of 4 Notes for home"], short)
        let front = try filed("front.pdf", ["Home program Page 1 of 4", "Page 2 of 4"])
        var someoneElse = Self.program
        someoneElse.person = "Sam_Example"
        let other = try filed("other.pdf", ["Home program Page 1 of 4", "Page 2 of 4"], someoneElse)
        let suggestions = Joining.suggestions([back, front, other])
        #expect(suggestions.map { $0.pieces.map(\.path) } == [[front.path, back.path]])
        #expect(suggestions.first?.pageCount == 4)
        #expect(Joining.suggestions([back, front, other], keepingSeparate: [suggestions[0].id]).isEmpty)
        #expect(Joining.ordered([back, front]).map(\.path) == [front.path, back.path])
    }

    @Test func overlappingOrIncompletePagesAreNotSuggested() throws {
        let one = try filed("one.pdf", ["Page 1 of 3", "Page 2 of 3"])
        let again = try filed("again.pdf", ["Page 2 of 3", "Page 3 of 3"])
        let short = try filed("short.pdf", ["Page 1 of 5", "Page 2 of 5"])
        let more = try filed("more.pdf", ["Page 3 of 5"])
        let whole = try filed("whole.pdf", ["Page 1 of 2", "Page 2 of 2"])
        let unnumbered = try filed("unnumbered.pdf", ["Notes for home"])
        #expect(Joining.suggestions([whole, unnumbered]).isEmpty)
        // Page 1 of one month's statement and page 2 of another's
        var later = Self.program
        later.documentDate = "2026-11-09"
        let november = try filed("november.pdf", ["Statement Page 2 of 2"], later)
        let june = try filed("june.pdf", ["Statement Page 1 of 2"])
        #expect(Joining.suggestions([june, november]).isEmpty)
        later.documentDate = ""
        let undated = try filed("undated.pdf", ["Statement Page 2 of 2"], later)
        #expect(Joining.suggestions([june, undated]).count == 1)
        #expect(Joining.suggestions([one, again]).isEmpty)
        // Pages 1 and 3 in one, 2 and 4 in the other: joined in turn, they'd be out of order
        let odd = try filed("odd.pdf", ["Page 1 of 4", "Page 3 of 4"])
        let even = try filed("even.pdf", ["Page 2 of 4", "Page 4 of 4"])
        #expect(Joining.suggestions([odd, even]).isEmpty)
        #expect(Joining.suggestions([short, more]).isEmpty)
    }

    @Test func joiningKeepsTheFirstDocumentAndUndoPutsThePiecesBack() throws {
        let front = try filed("front.pdf", ["Home program Page 1 of 4", "Page 2 of 4"])
        let back = try filed("back.pdf", ["Stretches Page 3 of 4", "Page 4 of 4"])
        let frontURL = URL(fileURLWithPath: front.path), backURL = URL(fileURLWithPath: back.path)
        try (frontURL as NSURL).setResourceValue(["Medical"], forKey: .tagNamesKey)
        let before = try Data(contentsOf: frontURL)

        let joined = try actions.join([front, back])
        let pages = PDFDocument(url: frontURL).map { pdf in (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" } } ?? []
        #expect(pages.count == 4 && pages[2].contains("Stretches"))
        #expect(try frontURL.resourceValues(forKeys: [.tagNamesKey]).tagNames == ["Medical"])
        #expect(!FileManager.default.fileExists(atPath: backURL.path))
        #expect(DocumentLibrary.load(index).documents.map(\.path) == [front.path])

        try actions.undo(joined)
        #expect(try Data(contentsOf: frontURL) == before)
        #expect(PDFDocument(url: backURL)?.pageCount == 2)
        #expect(Set(DocumentLibrary.load(index).documents.map(\.path)) == [front.path, back.path])
    }

    @Test func joiningNeedsTwoFiledDocuments() throws {
        let front = try filed("front.pdf", ["Page 1 of 2"])
        #expect(throws: ReviewActions.LibraryActionError.self) { try actions.join([front]) }
        #expect(throws: ReviewActions.LibraryActionError.self) { try actions.join([front, front]) }
    }

    @Test func nothingIsCombinedWhenAPieceCantBeReadOrHasChanged() throws {
        let front = try filed("front.pdf", ["Home program Page 1 of 2"])
        let broken = try filed("broken.pdf", ["Page 2 of 2"])
        try Data("not a pdf".utf8).write(to: URL(fileURLWithPath: broken.path))
        let before = try Data(contentsOf: URL(fileURLWithPath: front.path))
        #expect(throws: ReviewActions.LibraryActionError.self) { try actions.join([front, broken]) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: front.path)) == before)
        #expect(FileManager.default.fileExists(atPath: broken.path))

        // A list made before a document was replaced at that path doesn't act on the new one
        var stale = try filed("back.pdf", ["Page 2 of 2"])
        stale.documentID = "an-older-document"
        #expect(throws: ReviewActions.LibraryActionError.self) { try actions.join([front, stale]) }
        #expect(FileManager.default.fileExists(atPath: stale.path))
    }
}
