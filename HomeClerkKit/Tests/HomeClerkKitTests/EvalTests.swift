import Foundation
import Testing
@testable import HomeClerkKit

@Suite struct EvalScorerTests {
    let router = FilingRouter(TestData.taxonomy)

    func observed(_ facets: DocumentFacets) -> ObservedFacts {
        ObservedFacts(facets: facets, router: router, names: FilenameBuilder(TestData.taxonomy), confidence: 0.9,
                      splitCount: 0, reasoning: "")
    }

    @Test func scoresOnlyExpectedFieldsAndIgnoresPunctuation() {
        let c = EvalCase(id: "toll", expected: ExpectedFacts(area: "Vehicle", tags: ["tolls"], vendor: "Toll Authority",
                                                             documentDate: "2026-04-24", amount: Decimal(string: "31.40")))
        let score = EvalScorer.score(c, observed(DocumentFacets(documentType: "Bill", area: "Vehicle", tags: ["tolls"],
                                                                vendor: "Toll_Authority", documentDate: "2026-04-24",
                                                                amount: Decimal(string: "31.4"))), router: router)
        #expect(score.fields.map(\.field) == ["folder", "area", "tags", "vendor", "document_date", "amount"])
        #expect(score.passed == 6 && score.scored == 6)
    }

    @Test func missesAndUnconfirmedFieldsAreReported() {
        let c = EvalCase(id: "x", expected: ExpectedFacts(area: "Medical", vendor: "Summit Neurology"), verify: ["person"])
        let score = EvalScorer.score(c, observed(DocumentFacets(documentType: "Statement", area: "Medical",
                                                                vendor: "Other Clinic", person: "Jane_Smith")), router: router)
        #expect(score.fields.first { $0.field == "vendor" }?.status == .fail)
        #expect(score.fields.first { $0.field == "person" } == FieldResult(field: "person", expected: "?", actual: "Jane_Smith", status: .verify))
    }

    @Test func splitsAreScoredByTheirPages() {
        let router = FilingRouter(TestData.taxonomy), names = FilenameBuilder(TestData.taxonomy)
        func doc(_ first: Int, _ last: Int, _ type: String, _ vendor: String) -> FacetDocument {
            FacetDocument(firstPage: first, lastPage: last,
                          facets: DocumentFacets(documentType: type, area: "Shopping", vendor: vendor), confidence: 0.9)
        }
        let pile = EvalCase(id: "pile", expected: ExpectedFacts(), documents: [
            ExpectedDocument(firstPage: 1, lastPage: 2, expected: ExpectedFacts(documentType: "Bill", vendor: "Acme_Power")),
            ExpectedDocument(firstPage: 3, lastPage: 3, expected: ExpectedFacts(documentType: "Receipt", vendor: "Corner_Hardware")),
        ])
        let right = [doc(3, 3, "Receipt", "Corner_Hardware"), doc(1, 2, "Bill", "Acme_Power")]
        #expect(EvalScorer.split(pile, pageCount: 3, observed: right).status == .pass)
        #expect(EvalScorer.scoreDocuments(pile, observed: right, router: router, names: names).allSatisfy { $0.status == .pass })

        // Merged into one: the split fails, and so does every field of both documents, since
        // neither was split out at its own pages
        let merged = [doc(1, 3, "Bill", "Acme_Power")]
        let miss = EvalScorer.split(pile, pageCount: 3, observed: merged)
        #expect(miss.status == .fail && miss.expected == "1–2 | 3" && miss.actual == "1–3")
        let fields = EvalScorer.scoreDocuments(pile, observed: merged, router: router, names: names)
        #expect(fields.filter { $0.status == .fail }.count == 4 && fields.allSatisfy { $0.actual == "(not split out)" })

        // A one-document scan must not be split
        let single = EvalCase(id: "single", expected: ExpectedFacts(documentType: "Statement"))
        #expect(EvalScorer.split(single, pageCount: 2, observed: [doc(1, 2, "Statement", "")]).status == .pass)
        #expect(EvalScorer.split(single, pageCount: 2, observed: [doc(1, 1, "Statement", ""), doc(2, 2, "Statement", "")]).status == .fail)
    }
}
