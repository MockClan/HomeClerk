import Foundation

/// The household lists a document's names are matched against, and the facet each one fills.
public enum HouseholdKind: String, CaseIterable, Sendable, Codable {
    case people, groups, vehicles, pets, vendors

    public var title: String {
        switch self {
        case .people: "People"
        case .groups: "Groups"
        case .vehicles: "Vehicles"
        case .pets: "Pets"
        case .vendors: "Vendors"
        }
    }

    /// "person", for "Add Jordan to your household as a person?"
    public var singular: String {
        switch self {
        case .people: "person"
        case .groups: "group"
        case .vehicles: "vehicle"
        case .pets: "pet"
        case .vendors: "vendor"
        }
    }
}

/// An alias added from a correction: which entry it points at, and when.
public struct LearnedAlias: Equatable, Sendable {
    public var kind: HouseholdKind
    public var name: String
    public var alias: String
    /// yyyy-MM-dd
    public var date: String

    public init(kind: HouseholdKind, name: String, alias: String, date: String) {
        self.kind = kind
        self.name = name
        self.alias = alias
        self.date = date
    }

    init?(json: JSONValue) {
        guard let kind = json["kind"]?.stringValue.flatMap(HouseholdKind.init(rawValue:)),
              let name = json["name"]?.stringValue, let alias = json["alias"]?.stringValue else { return nil }
        self.init(kind: kind, name: name, alias: alias, date: json["date"]?.stringValue ?? "")
    }

    var json: JSONValue {
        .object([("kind", .string(kind.rawValue)), ("name", .string(name)), ("alias", .string(alias)), ("date", .string(date))])
    }
}

// MARK: - Editing

extension HouseholdProfile: Equatable {
    /// Equal by what's edited; the file as it was read doesn't count.
    public static func == (a: HouseholdProfile, b: HouseholdProfile) -> Bool {
        a.people == b.people && a.groups == b.groups && a.vehicles == b.vehicles && a.pets == b.pets
            && a.vendors == b.vendors && a.notes == b.notes && a.learned == b.learned
    }
}

extension HouseholdProfile {
    /// Names in a list, as the pickers offer them.
    public func names(_ kind: HouseholdKind) -> [String] {
        kind == .vehicles ? vehicles.map(\.name) : entries(kind).map(\.name)
    }

    /// The canonical name `value` already maps to in a list, if any.
    public func known(_ value: String, _ kind: HouseholdKind) -> String? {
        switch kind {
        case .people, .pets: Self.matchName(value, entries(kind))
        case .groups, .vendors: Self.match(value, entries(kind))
        case .vehicles: Self.match(value, vehicles.map { ProfileEntry(name: $0.name, aliases: $0.aliases) })
        }
    }

    /// Adds `alias` to the entry named `name`, so documents that say it file under that name.
    /// Does nothing when it already maps there. Returns whether anything changed.
    @discardableResult
    public mutating func remember(_ alias: String, as name: String, kind: HouseholdKind, today: String) -> Bool {
        let alias = alias.trimmingCharacters(in: .whitespaces)
        guard !alias.isEmpty, known(alias, kind) != name else { return false }
        // An alias means one name: take it off any other entry first, or the first match would win
        let key = TextRules.key(alias)
        if kind == .vehicles {
            guard let i = vehicles.firstIndex(where: { $0.name == name }) else { return false }
            for j in vehicles.indices { vehicles[j].aliases.removeAll { TextRules.key($0) == key } }
            vehicles[i].aliases.append(alias)
        } else {
            var list = entries(kind)
            guard let i = list.firstIndex(where: { $0.name == name }) else { return false }
            for j in list.indices { list[j].aliases.removeAll { TextRules.key($0) == key } }
            list[i].aliases.append(alias)
            setEntries(kind, list)
        }
        learned.append(LearnedAlias(kind: kind, name: name, alias: alias, date: today))
        return true
    }

    /// Adds a new entry; does nothing when the name is already known. Returns whether it was added.
    @discardableResult
    public mutating func add(_ name: String, kind: HouseholdKind, aliases: [String] = []) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, known(name, kind) == nil else { return false }
        if kind == .vehicles {
            vehicles.append(VehicleEntry(name: name, aliases: aliases))
        } else {
            setEntries(kind, entries(kind) + [ProfileEntry(name: name, aliases: aliases)])
        }
        return true
    }

    /// The learned record for an alias, if it came from a correction.
    public func learnedRecord(_ alias: String, kind: HouseholdKind) -> LearnedAlias? {
        learned.last { $0.kind == kind && TextRules.key($0.alias) == TextRules.key(alias) }
    }

    public func entries(_ kind: HouseholdKind) -> [ProfileEntry] {
        switch kind {
        case .people: people
        case .groups: groups
        case .vehicles: vehicles.map { ProfileEntry(name: $0.name, aliases: $0.aliases, notes: $0.notes) }
        case .pets: pets
        case .vendors: vendors
        }
    }

    public mutating func setEntries(_ kind: HouseholdKind, _ list: [ProfileEntry]) {
        switch kind {
        case .people: people = list
        case .groups: groups = list
        case .pets: pets = list
        case .vendors: vendors = list
        case .vehicles: break
        }
    }

    /// The profile as household.json: the lists HomeClerk edits, written over the file as it was
    /// read, so keys and fields it doesn't know about are kept.
    public var json: JSONValue {
        var pairs = raw?.objectPairs ?? []
        func set(_ key: String, _ value: JSONValue?) {
            pairs.removeAll { $0.key == key }
            if let value { pairs.append((key, value)) }
        }
        // Replace in place to keep the file's key order
        func put(_ key: String, _ value: JSONValue?) {
            if let i = pairs.firstIndex(where: { $0.key == key }) {
                if let value { pairs[i].value = value } else { pairs.remove(at: i) }
            } else {
                set(key, value)
            }
        }
        // Rows still being typed (no name yet) and blank note lines aren't written
        func named(_ list: [ProfileEntry]) -> JSONValue { .array(list.filter { !$0.name.isEmpty }.map(\.json)) }
        put("people", named(people))
        put("groups", groups.isEmpty && raw?["groups"] == nil ? nil : named(groups))
        put("vehicles", .array(vehicles.filter { !$0.name.isEmpty }.map(\.json)))
        put("pets", named(pets))
        put("vendors", named(vendors))
        put("notes", .array(notes.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(JSONValue.string)))
        put("learned", learned.isEmpty ? nil : .array(learned.map(\.json)))
        return .object(pairs)
    }

    /// Writes household.json, readable only by this account (it holds personal details).
    public func save(to url: URL) throws {
        try PrivateFile.write(Data((json.pretty() + "\n").utf8), to: url)
    }
}

/// Writes known fields over an entry's original object, keeping any others.
private func merged(_ raw: JSONValue?, _ fields: [(String, JSONValue?)]) -> JSONValue {
    var pairs = raw?.objectPairs ?? []
    for (key, value) in fields {
        if let i = pairs.firstIndex(where: { $0.key == key }) {
            if let value { pairs[i].value = value } else { pairs.remove(at: i) }
        } else if let value {
            pairs.append((key, value))
        }
    }
    return .object(pairs)
}

extension ProfileEntry {
    var json: JSONValue {
        merged(raw, [("name", .string(name)),
                     ("aliases", aliases.isEmpty ? nil : .array(aliases.map(JSONValue.string))),
                     ("notes", notes.isEmpty ? nil : .string(notes))])
    }
}

extension VehicleEntry {
    var json: JSONValue {
        merged(raw, [("name", .string(name)),
                     ("aliases", aliases.isEmpty ? nil : .array(aliases.map(JSONValue.string))),
                     ("vin", vin.isEmpty ? nil : .string(vin)),
                     ("plates", plates.isEmpty ? nil : .array(plates.map(JSONValue.string))),
                     ("notes", notes.isEmpty ? nil : .string(notes))])
    }
}

// MARK: - Noticed names

/// A name seen on a filed document that the household doesn't know — a new person, pet, or
/// vehicle, or a new spelling of a known vendor. Review asks about it without holding anything up.
public struct NoticedName: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(kind.rawValue):\(TextRules.key(value))" }
    public var kind: HouseholdKind
    public var value: String
    /// The filed document it was seen on.
    public var path: String
    public var noticedAt: Date
    /// For a vendor spelling: the known vendor it resembles.
    public var resembles: String?

    public init(kind: HouseholdKind, value: String, path: String, noticedAt: Date = Date(), resembles: String? = nil) {
        self.kind = kind
        self.value = value
        self.path = path
        // Whole seconds, as noticed.json stores it
        self.noticedAt = Date(timeIntervalSince1970: noticedAt.timeIntervalSince1970.rounded(.down))
        self.resembles = resembles
    }
}

public enum Noticing {
    /// Names in `facets` the household doesn't know. People, pets, and vehicles are always worth
    /// asking about; vendors only when they look like a misspelling of one already known (most
    /// vendors are new, and asking about each would be noise).
    public static func unknownNames(_ facets: DocumentFacets, profile: HouseholdProfile, path: String) -> [NoticedName] {
        var found: [NoticedName] = []
        func check(_ value: String, _ kinds: [HouseholdKind]) {
            guard !TextRules.key(value).isEmpty, kinds.allSatisfy({ profile.known(value, $0) == nil }) else { return }
            found.append(NoticedName(kind: kinds[0], value: value, path: path))
        }
        check(facets.person, [.people, .groups])
        check(facets.pet, [.pets])
        check(facets.vehicle, [.vehicles])
        let vendorKey = TextRules.key(facets.vendor)
        if !vendorKey.isEmpty, profile.known(facets.vendor, .vendors) == nil,
           let similar = profile.vendors.first(where: { entry in
               ([entry.name] + entry.aliases).contains { resembles(TextRules.key($0), vendorKey) }
           }) {
            found.append(NoticedName(kind: .vendors, value: facets.vendor, path: path, resembles: similar.name))
        }
        return found
    }

    /// Close enough to be the same name spelled differently: one or two letters apart.
    static func resembles(_ a: String, _ b: String) -> Bool {
        guard a != b, min(a.count, b.count) >= 4, abs(a.count - b.count) <= 2 else { return false }
        return distance(Array(a), Array(b)) <= 2
    }

    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }
}

/// Noticed names waiting for an answer, and ones you chose to ignore (never asked about again).
/// Kept in noticed.json beside household.json.
public final class NoticedStore: @unchecked Sendable {
    public static let fileName = "noticed.json"

    private struct Contents: Codable {
        var pending: [NoticedName] = []
        var ignored: [String] = []
    }

    public let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public func pending() -> [NoticedName] { lock.withLock { read().pending } }

    /// Adds names not already pending or ignored; returns the ones added.
    @discardableResult
    public func add(_ names: [NoticedName]) -> [NoticedName] {
        lock.withLock {
            var contents = read()
            let skip = Set(contents.pending.map(\.id)).union(contents.ignored)
            let new = names.filter { !skip.contains($0.id) }
            guard !new.isEmpty else { return [] }
            contents.pending += new
            write(contents)
            return new
        }
    }

    /// Answered: no longer pending.
    public func resolve(_ id: String) {
        lock.withLock {
            var contents = read()
            contents.pending.removeAll { $0.id == id }
            write(contents)
        }
    }

    /// Never ask about this name again.
    public func ignore(_ id: String) {
        lock.withLock {
            var contents = read()
            contents.pending.removeAll { $0.id == id }
            if !contents.ignored.contains(id) { contents.ignored.append(id) }
            write(contents)
        }
    }

    /// Puts a resolved or ignored name back, for undo.
    public func restore(_ name: NoticedName) {
        lock.withLock {
            var contents = read()
            contents.ignored.removeAll { $0 == name.id }
            if !contents.pending.contains(where: { $0.id == name.id }) { contents.pending.append(name) }
            write(contents)
        }
    }

    private func read() -> Contents { PrivateFile.readJSON(Contents.self, from: url) ?? Contents() }

    private func write(_ contents: Contents) { try? PrivateFile.writeJSON(contents, to: url) }
}
