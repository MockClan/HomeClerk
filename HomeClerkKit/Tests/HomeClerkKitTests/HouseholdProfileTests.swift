import Foundation
import Testing
@testable import HomeClerkKit

@Suite struct HouseholdProfileTests {
    let profile = HouseholdProfile(
        people: [ProfileEntry(name: "Jane_Smith"), ProfileEntry(name: "Sam_Smith", aliases: ["Samuel Smith"])],
        groups: [ProfileEntry(name: "Troop_101", aliases: ["Unit 101"])],
        vehicles: [VehicleEntry(name: "2021_Toyota_RAV4")],
        pets: [ProfileEntry(name: "Biscuit")],
        vendors: [ProfileEntry(name: "Acme_Tire", aliases: ["AcmeTire"])])

    func canonical(person: String = "", pet: String = "", vehicle: String = "", vendor: String = "") -> DocumentFacets {
        profile.canonicalize(DocumentFacets(vendor: vendor, person: person, vehicle: vehicle, pet: pet))
    }

    @Test(arguments: ["JANE_SMITH", "jane smith", "JANE_A_SMITH", "Jane_Q_Public_Smith"])
    func personVariantsMapToCanonicalName(raw: String) {
        #expect(canonical(person: raw).person == "Jane_Smith")
    }

    @Test func personAliasMapsToCanonicalName() { #expect(canonical(person: "SAMUEL_SMITH").person == "Sam_Smith") }

    @Test(arguments: ["Unit_101", "TROOP 101"])
    func groupAliasMapsToCanonicalName(raw: String) { #expect(canonical(person: raw).person == "Troop_101") }

    @Test func groupsAreListedInThePrompt() { #expect(profile.promptText().contains("- Troop_101")) }

    @Test func unknownShoutingNameBecomesTitleCase() { #expect(canonical(person: "JOHN_DOE").person == "John_Doe") }

    @Test func unknownMixedCaseNameIsLeftAlone() { #expect(canonical(person: "Pat_McDonald").person == "Pat_McDonald") }

    @Test func sharedLastNameAloneDoesNotMatch() { #expect(canonical(person: "Alex_Smith").person == "Alex_Smith") }

    @Test(arguments: ["AcmeTire", "ACME TIRE", "Acme_Tire"])
    func vendorAliasAndSpacingMapToCanonicalName(raw: String) { #expect(canonical(vendor: raw).vendor == "Acme_Tire") }

    @Test func vehicleAndPetIgnoreCaseAndPunctuation() {
        #expect(canonical(vehicle: "2021 toyota rav-4").vehicle == "2021_Toyota_RAV4")
        #expect(canonical(pet: "BISCUIT").pet == "Biscuit")
    }

    @Test func loadsAProfileWithCommentsAndTrailingCommas() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("household-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
            {
              // fictional household
              "people": [ { "name": "Jane_Smith", }, ],
              /* no pets yet */
            }
            """.write(to: url, atomically: true, encoding: .utf8)
        #expect(try HouseholdProfile.loadOrEmpty(from: url).people == [ProfileEntry(name: "Jane_Smith")])
    }

    @Test func missingFileIsAnEmptyProfile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).json")
        #expect(try HouseholdProfile.loadOrEmpty(from: url).isEmpty)
    }

    /// A known pet (or vehicle) put in the person field moves to its own field, so it isn't asked
    /// about as a new person or repeated in the file name.
    @Test func aKnownPetOrVehicleInThePersonFieldMovesOver() throws {
        let profile = HouseholdProfile(json: try JSONValue(parsing: """
            {"people": [{"name": "Jane_Smith"}], "pets": [{"name": "Biscuit"}], "vehicles": [{"name": "2021_Toyota_RAV4", "aliases": ["RAV4"]}]}
            """))
        let vet = profile.canonicalize(DocumentFacets(person: "Biscuit", pet: "Biscuit"))
        #expect(vet.person == "" && vet.pet == "Biscuit")
        let car = profile.canonicalize(DocumentFacets(person: "rav4"))
        #expect(car.person == "" && car.vehicle == "2021_Toyota_RAV4")
        // A real person stays, and a different pet already named isn't overwritten
        #expect(profile.canonicalize(DocumentFacets(person: "Jane Smith")).person == "Jane_Smith")
        let both = profile.canonicalize(DocumentFacets(person: "Biscuit", pet: "Mittens"))
        #expect(both.person == "Biscuit" && both.pet == "Mittens")
    }
}

