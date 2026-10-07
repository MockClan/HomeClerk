import Foundation
import Testing
@testable import HomeClerkKit

@Suite struct FacetPromptTests {
    let taxonomy = TestData.taxonomy

    @Test func listsEveryTypeAreaAndSuggestedTag() {
        let prompt = FacetPrompt.buildSystem(taxonomy, .empty)
        let names = taxonomy.documentTypes.map(\.name) + taxonomy.areas.map(\.name) + taxonomy.suggestedTags.map(\.tag)
        for name in names { #expect(prompt.contains("- \(name):")) }
    }

    /// The old prompt's "Today's date" line was used as a fallback document date, filing undated
    /// scans under the day they were scanned.
    @Test func neverContainsTodaysDate() {
        let prompt = FacetPrompt.buildSystem(taxonomy, .empty) + FacetPrompt.buildUserText(ocrText: "text", pageCount: 1)
        let today = Date().formatted(.iso8601.year().month().day())
        #expect(!prompt.contains(today))
        #expect(!prompt.localizedCaseInsensitiveContains("today"))
    }

    @Test func emptyProfileAddsNoHouseholdSection() {
        #expect(!FacetPrompt.buildSystem(taxonomy, .empty).contains("# Household"))
    }

    @Test func rendersHouseholdProfile() {
        let text = HouseholdProfile(
            people: [ProfileEntry(name: "Jane_Smith")],
            vehicles: [VehicleEntry(name: "2021_Toyota_RAV4", vin: "2T3P1RFV0MC000000")],
            pets: [ProfileEntry(name: "Biscuit", notes: "dog")],
            vendors: [ProfileEntry(name: "AHP", aliases: ["Acme Health Plan"])]).promptText()
        #expect(text.contains("- Jane_Smith"))
        #expect(text.contains("- 2021_Toyota_RAV4 — VIN 2T3P1RFV0MC000000"))
        #expect(text.contains("- Biscuit — dog"))
        #expect(text.contains("- AHP — also appears as \"Acme Health Plan\""))
    }

    @Test func userTextFlagsMissingOcr() {
        #expect(FacetPrompt.buildUserText(ocrText: "  ", pageCount: 2).contains("rely on the page images"))
    }

    @Test func summaryComesBeforeDocumentsInTheSchema() {
        guard case let .object(properties)? = FacetSchema.build(taxonomy)["properties"] else {
            Issue.record("schema has no properties")
            return
        }
        #expect(properties.map(\.key) == ["summary", "documents"])
    }
}
