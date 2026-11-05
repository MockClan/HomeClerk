import Foundation
import Testing
@testable import HomeClerkKit

@Suite struct DuplicateDetectorTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("homeclerk-dup-\(UUID())")

    // A form letter long enough for a stable fingerprint; only the recipient changes
    static func letter(_ recipient: String) -> String {
        "Dear \(recipient), we are writing to let you know about a data security incident involving a vendor " +
        "that provides services to your health plan. Information that may have been involved includes names, " +
        "addresses, dates of birth, and member identification numbers. We are offering complimentary credit " +
        "monitoring for twenty four months. Please call our dedicated assistance line with any questions."
    }

    static func facets(_ person: String, date: String = "2025-09-18", amount: Decimal? = nil) -> DocumentFacets {
        DocumentFacets(vendor: "Acme_Benefits", documentDate: date, amount: amount, person: person)
    }

    func detector() -> DuplicateDetector { DuplicateDetector(duplicatesFolder: folder, hammingThreshold: 3) }

    @Test func sameLetterToDifferentFamilyMembersIsNotADuplicate() {
        let d = detector()
        d.register(ocrText: Self.letter("Jane Smith"), sha256: "sha-a", facets: Self.facets("Jane_Smith"), label: "jane.pdf")
        #expect(d.nearDuplicate(ocrText: Self.letter("Sam Smith"), facets: Self.facets("Sam_Smith")) == nil)
    }

    @Test func sameStatementForADifferentMonthIsNotADuplicate() {
        let d = detector()
        d.register(ocrText: Self.letter("Jane Smith"), sha256: "sha-a",
                   facets: Self.facets("Jane_Smith", date: "2026-01-14", amount: 20), label: "a.pdf")
        #expect(d.nearDuplicate(ocrText: Self.letter("Jane Smith"),
                                facets: Self.facets("Jane_Smith", date: "2026-02-23", amount: 20)) == nil)
    }

    @Test func rescanWithSameTextAndFacetsIsADuplicate() {
        let d = detector()
        d.register(ocrText: Self.letter("Jane Smith"), sha256: "sha-a", facets: Self.facets("Jane_Smith"),
                   label: "Identity & Security/jane.pdf")
        // A rescan's OCR picks up a couple of misread characters; facets come out the same
        let rescan = Self.letter("Jane Smith").replacingOccurrences(of: "security", with: "securitv")
            .replacingOccurrences(of: "names", with: "narnes")
        #expect(d.nearDuplicate(ocrText: rescan, facets: Self.facets("Jane_Smith")) == "Identity & Security/jane.pdf")
    }

    @Test func theSameFormFilledInBySomeoneElseIsNotADuplicate() {
        // Course evaluations: one template, handwriting the OCR barely reads; the reader tells them apart
        let d = detector()
        var knots = Self.facets(""), cooking = Self.facets("")
        knots.description = "Knot_Tying_Course_Evaluation"
        cooking.description = "Camp_Cooking_Course_Evaluation"
        d.register(ocrText: Self.letter("member"), sha256: nil, facets: knots, label: "knots.pdf")
        #expect(d.nearDuplicate(ocrText: Self.letter("member"), facets: cooking) == nil)
        knots.description = "Knot Tying Course Evaluation"
        #expect(d.nearDuplicate(ocrText: Self.letter("member"), facets: knots) == "knots.pdf")
    }

    @Test func entriesRecordedBeforeDescriptionsCanBeGivenThem() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var knots = Self.facets(""), cooking = Self.facets("")
        knots.description = "Knot_Tying_Course_Evaluation"
        cooking.description = "Camp_Cooking_Course_Evaluation"
        let old = #"[{"fingerprint": \#(Simhash.compute(Self.letter("member"))), "label": "knots.pdf", "sha256": null, "key": "\#(DuplicateDetector.facetKey(knots))"}]"#
        try old.write(to: folder.appendingPathComponent(DuplicateDetector.indexFileName), atomically: true, encoding: .utf8)
        let d = detector()
        #expect(d.nearDuplicate(ocrText: Self.letter("member"), facets: cooking) == "knots.pdf")
        #expect(d.describe(["knots.pdf": knots]) == 1)
        #expect(detector().nearDuplicate(ocrText: Self.letter("member"), facets: cooking) == nil)
        #expect(d.describe(["knots.pdf": knots]) == 0)
    }

    @Test func aPersonOneReadingMissedStillMatches() {
        let d = detector()
        d.register(ocrText: Self.letter("Jane Smith"), sha256: "sha-a", facets: Self.facets(""), label: "contract.pdf")
        #expect(d.nearDuplicate(ocrText: Self.letter("Jane Smith"), facets: Self.facets("Jane_Smith")) == "contract.pdf")
        // The date and amount still have to agree
        #expect(d.nearDuplicate(ocrText: Self.letter("Jane Smith"), facets: Self.facets("Jane_Smith", date: "2025-09-19")) == nil)
        #expect(d.nearDuplicate(ocrText: Self.letter("Jane Smith"), facets: Self.facets("Jane_Smith", amount: 5)) == nil)
    }

    @Test func identicalFileIsAnExactDuplicateAndSurvivesRestart() {
        detector().register(ocrText: Self.letter("Jane Smith"), sha256: "sha-a", facets: Self.facets("Jane_Smith"), label: "jane.pdf")
        let reloaded = detector()
        #expect(reloaded.exactDuplicate(sha256: "sha-a") == "jane.pdf")
        #expect(reloaded.exactDuplicate(sha256: "sha-b") == nil)
    }

    @Test func splitSegmentsOnlyMatchExactly() {
        let d = detector()
        d.register(ocrText: Self.letter("Jane Smith"), sha256: "sha-a", facets: nil, label: "scan.pdf (split)")
        #expect(d.nearDuplicate(ocrText: Self.letter("Jane Smith"), facets: Self.facets("Jane_Smith")) == nil)
        #expect(d.exactDuplicate(sha256: "sha-a") != nil)
    }

    @Test func legacyIndexEntriesAreIgnored() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"[{"Fingerprint": 123, "Label": "old.pdf"}]"#
            .write(to: folder.appendingPathComponent(DuplicateDetector.indexFileName), atomically: true, encoding: .utf8)
        #expect(detector().nearDuplicate(ocrText: Self.letter("Jane Smith"), facets: Self.facets("Jane_Smith")) == nil)
    }

    /// The duplicate index as the original version wrote it: still read, and written the same way.
    @Test func readsTheIndexFormatTheCurrentAppWrites() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
            [
              {
                "fingerprint": 18446744073709551615,
                "label": "Bills - Utilities/2026-02-03-Acme_Power-Electric_Bill-88.12.pdf",
                "sha256": "abc",
                "key": "acmepower|2026-02-03||88.12||"
              }
            ]
            """.write(to: folder.appendingPathComponent(DuplicateDetector.indexFileName), atomically: true, encoding: .utf8)
        #expect(detector().exactDuplicate(sha256: "abc") == "Bills - Utilities/2026-02-03-Acme_Power-Electric_Bill-88.12.pdf")
    }

    @Test func facetKeyIgnoresCaseAndPunctuation() {
        #expect(DuplicateDetector.facetKey(DocumentFacets(vendor: "Acme Power, Inc.", documentDate: "2026-02-03",
                                                          amount: Decimal(string: "88.1"), person: "JANE_SMITH"))
                == "acmepowerinc|2026-02-03|janesmith|88.10||")
    }
}
