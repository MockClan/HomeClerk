import Foundation
import Testing
@testable import HomeClerkKit

@Suite struct TaxonomyTests {
    let router = FilingRouter(TestData.taxonomy)
    let names = FilenameBuilder(TestData.taxonomy)

    static func facets(_ area: String, _ type: String, _ tags: String...) -> DocumentFacets {
        DocumentFacets(documentType: type, area: area, tags: tags)
    }

    @Test func shippedTaxonomyIsValid() {
        #expect(TestData.taxonomy.validate().isEmpty)
    }

    /// A rule that can never fire means an earlier rule shadows it — almost always an ordering mistake.
    @Test func everyRuleIsReachable() {
        for (i, rule) in TestData.taxonomy.rules.enumerated() {
            let probe = DocumentFacets(documentType: rule.condition.types?.first ?? "Other",
                                       area: rule.condition.area ?? "Other",
                                       tags: rule.condition.tagsAny.map { [$0[0]] } ?? [])
            #expect(router.folder(for: probe) == rule.folder, "rules[\(i)] (\(rule.folder)) is shadowed by an earlier rule")
        }
    }

    // Each row mirrors where a document is filed today, so the facet model reproduces the folder layout
    @Test(arguments: [
        ("Medical", "Prior Authorization", "", "Medical - Prior Authorization"),
        ("Medical", "Appeal", "", "Medical - Insurance (EOB)"),
        ("Medical", "Explanation of Benefits", "dental", "Medical - Dental"),
        ("Medical", "Statement", "", "Medical - Bills"),
        ("Insurance", "Notice", "cobra", "Insurance - Health"),
        ("Financial", "Statement", "loan", "Financial - Loans"),
        ("Taxes", "Tax Form", "w2", "Financial - Taxes - W2"),
        ("Utilities", "Bill", "tolls", "Vehicle - Tolls"),
        ("Vehicle", "Warranty", "", "Warranties & Manuals"),
        ("Scouting", "Form", "health-form", "Scouting - Health Forms"),
        ("Insurance", "Notice", "data-breach", "Identity & Security"),
        ("Devices", "Receipt", "", "Devices"),
        ("Devices", "Warranty", "", "Warranties & Manuals"),
        ("Devices", "Record", "work-expense", "Employment - Expenses"),
        ("Vehicle", "Bill", "work-expense", "Employment - Expenses"),
        ("Other", "Other", "", "Uncategorized")
    ])
    func routesToExpectedFolder(area: String, type: String, tag: String, expected: String) {
        let facets = tag.isEmpty ? Self.facets(area, type) : Self.facets(area, type, tag)
        #expect(router.folder(for: facets) == expected)
    }

    @Test func unknownAreaFallsBackToAreaFolder() {
        let custom = TaxonomyConfig(documentTypes: [NamedEntry(name: "Other")],
                                    areas: [NamedEntry(name: "Other"), NamedEntry(name: "Hobbies")])
        #expect(FilingRouter(custom).folder(for: Self.facets("Hobbies", "Other")) == "Hobbies")
    }

    @Test func validationListsEveryProblem() {
        let broken = TaxonomyConfig(documentTypes: [NamedEntry(name: "Bill")], areas: [],
                                    rules: [FilingRule(folder: " ", condition: FacetCondition(area: "Space"))])
        #expect(broken.validate() == [
            "areas is empty", "areas must include \"Other\"", "documentTypes must include \"Other\"",
            "rules[0] ( ): unknown area \"Space\"", "rules[0]: folder is empty"
        ])
    }

    @Test func buildsFilenameWithSubjectAndAmount() {
        var f = Self.facets("Medical", "Statement")
        f.documentDate = "2026-01-14"
        f.vendor = "Summit Neurology of Ohio"
        f.person = "Jane_Smith"
        f.description = "Patient Statement"
        f.amount = Decimal(string: "120.50")
        #expect(names.build(f) == "2026-01-14-Summit_Neurology-Jane_Smith-Patient_Statement-120.50.pdf")
    }

    @Test func omitsAmountWhenTypeDoesNotCarryOne() {
        var f = Self.facets("Financial", "Statement", "loan")
        f.documentDate = "2026-04-15"
        f.vendor = "Acme_Auto_Finance"
        f.vehicle = "2021_Toyota_RAV4"
        f.description = "Auto_Loan_Statement"
        f.amount = 412
        #expect(names.build(f) == "2026-04-15-Acme_Auto_Finance-2021_Toyota_RAV4-Auto_Loan_Statement.pdf")
    }

    @Test(arguments: [("1987", "1987-Seller-Bill_of_Sale.pdf"), ("", "Undated-Seller-Bill_of_Sale.pdf"),
                      ("March 1987", "Undated-Seller-Bill_of_Sale.pdf")])
    func handlesPartialAndMissingDates(date: String, expected: String) {
        var f = Self.facets("Vehicle", "Contract", "title")
        f.documentDate = date
        f.vendor = "Seller"
        f.description = "Bill_of_Sale"
        #expect(names.build(f) == expected)
    }

    @Test func doesNotRepeatASegment() {
        var f = Self.facets("Pet", "Certificate")
        f.documentDate = "2026-03-09"
        f.vendor = "Sunny_Vet"
        f.person = "Biscuit"
        f.pet = "biscuit"
        f.description = "Rabies_Certificate"
        #expect(names.build(f) == "2026-03-09-Sunny_Vet-Biscuit-Rabies_Certificate.pdf")
    }

    @Test func stripsCharactersThatBreakPaths() {
        var f = Self.facets("Medical", "Claim")
        f.documentDate = "2025-11-05"
        f.vendor = "AHP"
        f.description = "Subrogation_Request\\"
        #expect(names.build(f) == "2025-11-05-AHP-Subrogation_Request.pdf")
    }

    @Test(arguments: [("The_Acme_Bank", "Acme_Bank"), ("Acme_Inc_LLC", "Acme"), ("Acme_Bank_of_Ohio", "Acme_Bank"),
                      ("Acme_of_Narnia", "Acme_of_Narnia"), ("Acme_Bank_of_Ohio_N.A.", "Acme_Bank"),
                      ("Bank_of_America", "Bank_of_America"), ("University_of_Ohio", "University_of_Ohio"),
                      ("Acme_Motors_of_America_Inc", "Acme_Motors")])
    func normalizesVendorNames(raw: String, expected: String) {
        #expect(VendorName.normalize(raw) == expected)
    }
}
