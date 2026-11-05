import Foundation
import Testing
@testable import HomeClerkKit

/// The same paper filed twice. Fictional documents; nothing here comes from real ones.
@Suite struct FiledDuplicatesTests {
    static let statement = """
        EXAMPLE CLINIC Patient statement for Pat Example. Statement date June 9 2026. Account 0000-1111.
        Office visit and follow up consultation billed to insurance; insurance paid its share and the
        remaining balance is yours. Please pay the amount due by July 1 2026 using the enclosed slip or
        online. Questions about this statement can be answered by our billing office weekdays.
        """
    static let backPage = """
        Ways to pay: mail a check with the payment slip, pay online with a card, or call the billing office.
        Financial assistance is available for patients who qualify; ask for an application at the front desk.
        """

    static func facets(person: String = "Pat_Example", date: String = "2026-06-09", amount: Decimal? = 40,
                       description: String = "Patient_Statement") -> DocumentFacets {
        DocumentFacets(documentType: "Statement", area: "Medical", vendor: "Example_Clinic", description: description,
                       documentDate: date, amount: amount, person: person)
    }

    static func entry(_ name: String, source: String, _ facets: DocumentFacets = facets(), filed: TimeInterval = 0) -> DocumentIndex.Entry {
        var entry = DocumentIndex.Entry(path: "/Organized/Medical - Bills/\(name)", source: source, pages: [], model: "m",
                                        confidence: 0.9, summary: "", facets: facets)
        entry.filedAt = Date(timeIntervalSince1970: 1_800_000_000 + filed)
        return entry
    }

    @Test func aRescanDescribedDifferentlyIsFoundAndTheFullerCopyKept() {
        let first = Self.entry("statement.pdf", source: "pile-a.pdf", filed: 0)
        let again = Self.entry("statement_2.pdf", source: "pile-b.pdf", Self.facets(person: "", description: "Account_Summary"), filed: 60)
        let found = FiledDuplicates.find([first, again], texts: [first.path: Self.statement, again.path: Self.statement])
        #expect(found.map(\.extra.path) == [again.path])
        #expect(found.first?.keep.path == first.path && found.first?.partial == false)
    }

    @Test func aCopyOfSomeOfThePagesIsFoundAsPartial() {
        let firstPage = Self.entry("page-one.pdf", source: "old.pdf")
        let whole = Self.entry("whole.pdf", source: "pile.pdf")
        let found = FiledDuplicates.find([firstPage, whole], texts: [firstPage.path: Self.statement,
                                                                     whole.path: Self.statement + Self.backPage + Self.backPage])
        #expect(found.map { [$0.keep.path, $0.extra.path] } == [[whole.path, firstPage.path]])
        #expect(found.first?.partial == true)
    }

    @Test func differentDetailsOrTheSameScanAreNotDuplicates() {
        let june = Self.entry("june.pdf", source: "a.pdf")
        let july = Self.entry("july.pdf", source: "b.pdf", Self.facets(date: "2026-07-09"))
        let more = Self.entry("more.pdf", source: "c.pdf", Self.facets(amount: 55))
        let other = Self.entry("other.pdf", source: "d.pdf", Self.facets(person: "Sam_Example"))
        let sameScan = Self.entry("copy.pdf", source: "a.pdf")
        let texts = Dictionary(uniqueKeysWithValues: [june, july, more, other, sameScan].map { ($0.path, Self.statement) })
        #expect(FiledDuplicates.find([june, july], texts: texts).isEmpty)
        #expect(FiledDuplicates.find([june, more], texts: texts).isEmpty)
        #expect(FiledDuplicates.find([june, other], texts: texts).isEmpty)
        // Several copies of one form in one pile are deliberate
        #expect(FiledDuplicates.find([june, sameScan], texts: texts).isEmpty)
    }

    @Test func pairsYouKeepArentListedAgain() {
        let first = Self.entry("statement.pdf", source: "a.pdf"), again = Self.entry("statement_2.pdf", source: "b.pdf", filed: 60)
        let texts = [first.path: Self.statement, again.path: Self.statement]
        let pair = FiledDuplicates.find([first, again], texts: texts)[0]
        #expect(FiledDuplicates.find([first, again], texts: texts, keepingBoth: [pair.id]).isEmpty)
    }
}
