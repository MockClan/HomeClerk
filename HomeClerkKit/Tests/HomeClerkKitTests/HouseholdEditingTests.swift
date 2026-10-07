import Foundation
import Testing
@testable import HomeClerkKit

/// Fictional household; nothing here comes from real documents.
@Suite struct HouseholdEditingTests {
    let temp = TempFolder()

    static let file = """
    {
      // a comment the app's editor will drop, like any JSON writer
      "people": [ { "name": "Pat_Example", "aliases": ["P Example"], "favoriteColor": "teal" } ],
      "vehicles": [ { "name": "2019_Example_Wagon", "vin": "TESTVIN000" } ],
      "pets": [],
      "vendors": [ { "name": "Acme_Power" } ],
      "notes": ["Utility bills go under Utilities."],
      "customSection": { "keep": true }
    }
    """

    func profile() throws -> HouseholdProfile { HouseholdProfile(json: try JSONValue(parsing: Self.file)) }

    @Test func savingKeepsFieldsHomeClerkDoesNotEdit() throws {
        var profile = try profile()
        profile.add("Jordan_Example", kind: .people)
        let url = temp.url.appendingPathComponent("household.json")
        try profile.save(to: url)

        let saved = try JSONValue(parsing: String(contentsOf: url, encoding: .utf8))
        #expect(saved.objectPairs?.map(\.key) == ["people", "vehicles", "pets", "vendors", "notes", "customSection"])
        #expect(saved["customSection"]?["keep"] == .bool(true))
        #expect(saved["people"]?.arrayValue?.first?["favoriteColor"] == .string("teal"))
        #expect(try HouseholdProfile.loadOrEmpty(from: url).names(.people) == ["Pat_Example", "Jordan_Example"])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func rememberingAnAliasMakesItCanonicalize() throws {
        var profile = try profile()
        let r1 = profile.remember("ACME PWR CO", as: "Acme_Power", kind: .vendors, today: "2026-10-05")
        #expect(r1)
        let again = profile.remember("acme pwr co", as: "Acme_Power", kind: .vendors, today: "2026-10-05")
        #expect(!again)   // already known
        #expect(profile.canonicalize(DocumentFacets(vendor: "Acme_Pwr_Co")).vendor == "Acme_Power")
        #expect(profile.learnedRecord("ACME PWR CO", kind: .vendors)?.date == "2026-10-05")

        let r2 = profile.remember("Old Wagon", as: "2019_Example_Wagon", kind: .vehicles, today: "2026-10-05")
        #expect(r2)
        #expect(profile.canonicalize(DocumentFacets(vehicle: "old wagon")).vehicle == "2019_Example_Wagon")

        let reloaded = HouseholdProfile(json: profile.json)
        #expect(reloaded.learned.count == 2 && reloaded.vendors.first?.aliases == ["ACME PWR CO"])
    }

    @Test func rememberingMovesAnAliasFromAnotherEntry() throws {
        var profile = try profile()
        profile.add("Jordan_Example", kind: .people)
        // "P Example" was Pat's; remembering it as Jordan's makes it Jordan's alone
        profile.remember("P Example", as: "Jordan_Example", kind: .people, today: "2026-10-05")
        #expect(profile.people.first { $0.name == "Pat_Example" }?.aliases == [])
        #expect(profile.known("P Example", .people) == "Jordan_Example")
    }

    @Test func addingSkipsNamesAlreadyKnown() throws {
        var profile = try profile()
        let r3 = profile.add("P Example", kind: .people)
        #expect(!r3)
        let r4 = profile.add("Biscuit", kind: .pets)
        #expect(r4)
        #expect(profile.known("biscuit", .pets) == "Biscuit")
    }

    @Test func noticesUnknownNamesAndVendorMisspellingsOnly() throws {
        let profile = try profile()
        let facets = DocumentFacets(vendor: "Acme_Powr", person: "Jordan_Example", vehicle: "2019_Example_Wagon", pet: "Biscuit")
        let noticed = Noticing.unknownNames(facets, profile: profile, path: "/x.pdf")
        #expect(noticed.map(\.kind) == [.people, .pets, .vendors])
        #expect(noticed.last?.resembles == "Acme_Power")
        // A brand-new vendor is normal, not worth asking about
        #expect(Noticing.unknownNames(DocumentFacets(vendor: "Sunny_Vet"), profile: profile, path: "/x.pdf").isEmpty)
    }

    @Test func noticedStoreSkipsPendingAndIgnoredNames() {
        let store = NoticedStore(url: temp.url.appendingPathComponent(NoticedStore.fileName))
        let jordan = NoticedName(kind: .people, value: "Jordan_Example", path: "/a.pdf")
        #expect(store.add([jordan]).count == 1)
        #expect(store.add([NoticedName(kind: .people, value: "JORDAN EXAMPLE", path: "/b.pdf")]).isEmpty)   // same name
        store.ignore(jordan.id)
        #expect(store.pending().isEmpty)
        #expect(store.add([jordan]).isEmpty)
        store.restore(jordan)
        #expect(store.pending() == [jordan])
    }
}

@Suite struct RefileTests {
    let temp = TempFolder()
    var settings: HomeClerkSettings { HomeClerkSettings(values: ["basepath": .string(temp.url.path)]) }
    var index: DocumentIndex { DocumentIndex(url: temp.url.appendingPathComponent("index.jsonl")) }

    func actions(_ duplicates: DuplicateDetector) -> ReviewActions {
        ReviewActions(settings: settings, taxonomy: TestData.taxonomy,
                      finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "x",
                                         expirationLeadDays: 30),
                      index: index, duplicates: duplicates)
    }

    @Test func correctingAFiledDocumentMovesItAndUndoPutsItBack() async throws {
        let duplicates = DuplicateDetector(duplicatesFolder: settings.duplicatesFolder)
        let actions = actions(duplicates)
        let facets = DocumentFacets(documentType: "Bill", area: "Utilities", vendor: "Acme_Pwr_Co", description: "Electric_Bill",
                                    documentDate: "2026-02-03", amount: Decimal(string: "88.12"))
        let folder = settings.outboxFolder.appendingPathComponent("Bills - Utilities")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("2026-02-03-Acme_Pwr_Co-Electric_Bill-88.12.pdf")
        try TestPDF.make(original, pages: ["Acme Power statement"])
        let entry = DocumentIndex.Entry(path: original.path, source: "scan.pdf", pages: [1, 1], model: "m", confidence: 0.9,
                                        summary: "A bill.", facets: facets)
        try index.append(entry)

        var fixed = facets
        fixed.vendor = "Acme_Power"
        let refiling = try await actions.refile(entry, facets: fixed, folder: nil)
        let moved = folder.appendingPathComponent("2026-02-03-Acme_Power-Electric_Bill-88.12.pdf")
        #expect(refiling.after.path == moved.path)
        #expect(FileManager.default.fileExists(atPath: moved.path) && !FileManager.default.fileExists(atPath: original.path))
        #expect(DocumentLibrary.load(index).documents.map(\.path) == [moved.path])
        #expect(DocumentLibrary.load(index).documents.first?.source == "scan.pdf")

        // Unchanged details leave the file where it is
        #expect(try await actions.refile(refiling.after, facets: fixed, folder: nil).after.path == moved.path)

        try await actions.undo(refiling)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(DocumentLibrary.load(index).documents.first?.facets.vendor == "Acme_Pwr_Co")
    }

    @Test func aChosenFolderOverridesTheRules() async throws {
        let actions = actions(DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
        let facets = DocumentFacets(documentType: "Bill", area: "Utilities", vendor: "Acme_Power", description: "Electric_Bill",
                                    documentDate: "2026-02-03")
        #expect(actions.destination(facets, folder: "Legal").folder == "Legal")
        #expect(actions.destination(facets, folder: "").folder == actions.destination(facets).folder)
    }
}
