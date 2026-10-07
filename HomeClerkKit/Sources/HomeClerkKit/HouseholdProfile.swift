import Foundation

/// What the household knows that a document doesn't say: who lives here, the groups they belong
/// to, which vehicles and pets it has, and what familiar vendors are (e.g. an installment lender
/// that always files as a loan). Rendered into the prompt so the model uses canonical names.
/// Holds personal data, so it lives in the HomeClerk folder (household.json), never the repository.
public struct HouseholdProfile: Sendable {
    public static let fileName = "household.json"
    public static let empty = HouseholdProfile()

    public var people: [ProfileEntry] = []
    /// Teams, troops, classes, and other units household members belong to. A document about the
    /// group as a whole (a roster, a unit's test record) names the group in the person field.
    public var groups: [ProfileEntry] = []
    public var vehicles: [VehicleEntry] = []
    public var pets: [ProfileEntry] = []
    public var vendors: [ProfileEntry] = []
    /// Free-form facts about how this household files things.
    public var notes: [String] = []
    /// Aliases learned from corrections, so the Household settings can say where each came from.
    public var learned: [LearnedAlias] = []
    /// The file as read, so saving keeps anything HomeClerk doesn't edit.
    var raw: JSONValue?

    public init(people: [ProfileEntry] = [], groups: [ProfileEntry] = [], vehicles: [VehicleEntry] = [],
                pets: [ProfileEntry] = [], vendors: [ProfileEntry] = [], notes: [String] = []) {
        self.people = people
        self.groups = groups
        self.vehicles = vehicles
        self.pets = pets
        self.vendors = vendors
        self.notes = notes
    }

    init(json: JSONValue) {
        func entries(_ key: String) -> [ProfileEntry] { json[key]?.arrayValue?.map(ProfileEntry.init(json:)) ?? [] }
        people = entries("people")
        groups = entries("groups")
        vehicles = json["vehicles"]?.arrayValue?.map(VehicleEntry.init(json:)) ?? []
        pets = entries("pets")
        vendors = entries("vendors")
        notes = json["notes"]?.stringArray ?? []
        learned = json["learned"]?.arrayValue?.compactMap(LearnedAlias.init(json:)) ?? []
        raw = json
    }

    /// Loads the profile, or returns `empty` when the file doesn't exist.
    public static func loadOrEmpty(from url: URL) throws -> HouseholdProfile {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        return HouseholdProfile(json: try JSONValue(parsing: String(contentsOf: url, encoding: .utf8)))
    }

    public var isEmpty: Bool {
        people.isEmpty && groups.isEmpty && vehicles.isEmpty && pets.isEmpty && vendors.isEmpty && notes.isEmpty
    }

    /// Prompt section describing the household; empty when there's nothing to say.
    public func promptText() -> String {
        guard !isEmpty else { return "" }
        var out = ""
        func line(_ text: String = "") { out += text + "\n" }

        if !people.isEmpty {
            line("People in the household (use these exact names for the person field):")
            for p in people { line("- \(Self.describe(p))") }
            line()
        }
        if !groups.isEmpty {
            line("Groups household members belong to (use these exact names for the person field when a " +
                 "document is about the group as a whole):")
            for g in groups { line("- \(Self.describe(g))") }
            line()
        }
        if !vehicles.isEmpty {
            line("Vehicles (use these exact ids for the vehicle field; match by VIN when one is printed):")
            for v in vehicles {
                var details: [String] = []
                if !v.vin.isEmpty { details.append("VIN \(v.vin)") }
                if !v.plates.isEmpty { details.append("plates \(v.plates.joined(separator: ", "))") }
                if !v.notes.isEmpty { details.append(v.notes) }
                line("- \(v.name)\(details.isEmpty ? "" : " — " + details.joined(separator: "; "))")
            }
            line()
        }
        if !pets.isEmpty {
            line("Pets (use these exact names for the pet field):")
            for p in pets { line("- \(Self.describe(p))") }
            line()
        }
        if !vendors.isEmpty {
            line("Known vendors (use the name before any dash as the vendor value):")
            for v in vendors { line("- \(Self.describe(v))") }
            line()
        }
        let notes = notes.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !notes.isEmpty {
            line("Household filing notes:")
            for n in notes { line("- \(n)") }
        }
        return out.trimmingTrailingWhitespace()
    }

    /// Maps the model's person (or group), vehicle, pet, and vendor values onto this profile's
    /// canonical names, so "JANE_A_SMITH", "AcmeTire", and "acme tire" all file the same way. The
    /// prompt asks for canonical names; this enforces them. Unknown ALL-CAPS names become Title_Case.
    public func canonicalize(_ facets: DocumentFacets) -> DocumentFacets {
        var f = facets
        // A model sometimes puts a known pet or vehicle in the person field ("Biscuit" on a vet
        // receipt). When the name is exactly one of them, move it where it belongs.
        if Self.matchName(facets.person, people) == nil, Self.match(facets.person, groups) == nil {
            let vehicleEntries = vehicles.map { ProfileEntry(name: $0.name, aliases: $0.aliases) }
            if let pet = Self.matchName(facets.person, pets), facets.pet.isEmpty || Self.matchName(facets.pet, pets) == pet {
                f.pet = pet
                f.person = ""
            } else if let vehicle = Self.match(facets.person, vehicleEntries),
                      facets.vehicle.isEmpty || Self.match(facets.vehicle, vehicleEntries) == vehicle {
                f.vehicle = vehicle
                f.person = ""
            }
        }
        let facets = f
        f.person = Self.matchName(facets.person, people) ?? Self.match(facets.person, groups)
            ?? Self.titleCaseIfShouting(facets.person)
        f.pet = Self.matchName(facets.pet, pets) ?? Self.titleCaseIfShouting(facets.pet)
        f.vehicle = Self.match(facets.vehicle, vehicles.map { ProfileEntry(name: $0.name, aliases: $0.aliases) }) ?? facets.vehicle
        f.vendor = Self.match(facets.vendor, vendors) ?? facets.vendor
        return f
    }

    /// Exact match ignoring case, spacing, and punctuation — against names and aliases.
    static func match(_ value: String, _ entries: [ProfileEntry]) -> String? {
        let key = TextRules.key(value)
        guard !key.isEmpty else { return nil }
        return entries.first { TextRules.key($0.name) == key || $0.aliases.contains { TextRules.key($0) == key } }?.name
    }

    /// Like `match`, but also matches first and last name when a middle name or initial differs.
    static func matchName(_ value: String, _ entries: [ProfileEntry]) -> String? {
        if let exact = match(value, entries) { return exact }
        let words = words(value)
        guard words.count >= 2 else { return nil }
        return entries.first { entry in
            ([entry.name] + entry.aliases).map(Self.words).contains {
                $0.count >= 2 && $0.first == words.first && $0.last == words.last
            }
        }?.name
    }

    private static func words(_ value: String) -> [String] {
        value.split(whereSeparator: { " _-.".contains($0) }).map { $0.lowercased() }
    }

    private static func titleCaseIfShouting(_ value: String) -> String {
        let letters = value.unicodeScalars.filter(TextRules.isLetter)
        guard !letters.isEmpty, letters.allSatisfy(TextRules.isUppercase) else { return value }
        return words(value).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "_")
    }

    private static func describe(_ e: ProfileEntry) -> String {
        var details: [String] = []
        if !e.aliases.isEmpty {
            details.append("also appears as " + e.aliases.map { "\"\($0)\"" }.joined(separator: ", "))
        }
        if !e.notes.isEmpty { details.append(e.notes) }
        return details.isEmpty ? e.name : "\(e.name) — \(details.joined(separator: "; "))"
    }
}

public struct ProfileEntry: Equatable, Sendable {
    public var name: String
    public var aliases: [String]
    public var notes: String
    var raw: JSONValue?

    public init(name: String, aliases: [String] = [], notes: String = "") {
        self.name = name
        self.aliases = aliases
        self.notes = notes
    }

    init(json: JSONValue) {
        name = json["name"]?.stringValue ?? ""
        aliases = json["aliases"]?.stringArray ?? []
        notes = json["notes"]?.stringValue ?? ""
        raw = json
    }

    /// Equal by what's edited; the original JSON doesn't count.
    public static func == (a: ProfileEntry, b: ProfileEntry) -> Bool {
        a.name == b.name && a.aliases == b.aliases && a.notes == b.notes
    }
}

public struct VehicleEntry: Equatable, Sendable {
    /// YYYY_Make_Model, used verbatim in file names.
    public var name: String
    public var aliases: [String]
    public var vin: String
    public var plates: [String]
    public var notes: String
    var raw: JSONValue?

    public init(name: String, aliases: [String] = [], vin: String = "", plates: [String] = [], notes: String = "") {
        self.name = name
        self.aliases = aliases
        self.vin = vin
        self.plates = plates
        self.notes = notes
    }

    init(json: JSONValue) {
        name = json["name"]?.stringValue ?? ""
        aliases = json["aliases"]?.stringArray ?? []
        vin = json["vin"]?.stringValue ?? ""
        plates = json["plates"]?.stringArray ?? []
        notes = json["notes"]?.stringValue ?? ""
        raw = json
    }

    public static func == (a: VehicleEntry, b: VehicleEntry) -> Bool {
        a.name == b.name && a.aliases == b.aliases && a.vin == b.vin && a.plates == b.plates && a.notes == b.notes
    }
}

extension String {
    /// Drops trailing whitespace and newlines.
    func trimmingTrailingWhitespace() -> String {
        var s = Substring(self)
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return String(s)
    }
}
