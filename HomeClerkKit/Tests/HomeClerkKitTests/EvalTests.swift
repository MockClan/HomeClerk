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
}
