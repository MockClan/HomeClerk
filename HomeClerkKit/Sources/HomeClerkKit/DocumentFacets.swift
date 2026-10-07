import Foundation

/// What the AI reads off a document, independent of where it gets filed. `FilingRouter` maps
/// these facets to a folder and `FilenameBuilder` assembles the file name, so folder layout and
/// naming can change in taxonomy.json without re-analyzing any documents.
public struct DocumentFacets: Codable, Equatable, Sendable {
    /// What the document is — one of the taxonomy's document types.
    public var documentType = "Other"
    /// Area of household life — one of the taxonomy's areas.
    public var area = "Other"
    /// Open-ended lowercase-kebab tags (e.g. "dental", "tolls", "data-breach").
    public var tags: [String] = []
    /// Shortest widely recognized issuer name, underscores for spaces.
    public var vendor = ""
    /// 2–4 word description of what the document is, underscores for spaces.
    public var description = ""
    /// Date printed on the document (statement, service, issue date), yyyy-MM-dd.
    public var documentDate = ""
    /// Payment due date, if any, yyyy-MM-dd.
    public var dueDate = ""
    /// Expiration, renewal, or end-of-coverage date, if any, yyyy-MM-dd.
    public var expiresOn = ""
    /// Total amount due, charged, or paid; nil when the document has none.
    public var amount: Decimal?
    /// Who the document is about — a household member or group (patient, employee, troop), First_Last.
    public var person = ""
    /// Vehicle the document is about, YYYY_Make_Model.
    public var vehicle = ""
    /// Pet the document is about.
    public var pet = ""

    public init(documentType: String = "Other", area: String = "Other", tags: [String] = [],
                vendor: String = "", description: String = "", documentDate: String = "",
                dueDate: String = "", expiresOn: String = "", amount: Decimal? = nil,
                person: String = "", vehicle: String = "", pet: String = "") {
        self.documentType = documentType
        self.area = area
        self.tags = tags
        self.vendor = vendor
        self.description = description
        self.documentDate = documentDate
        self.dueDate = dueDate
        self.expiresOn = expiresOn
        self.amount = amount
        self.person = person
        self.vehicle = vehicle
        self.pet = pet
    }

    public func hasTag(_ tag: String) -> Bool {
        tags.contains { TextRules.equalsIgnoringCase($0, tag) }
    }

    enum CodingKeys: String, CodingKey {
        case documentType = "document_type", area, tags, vendor, description
        case documentDate = "document_date", dueDate = "due_date", expiresOn = "expires_on"
        case amount, person, vehicle, pet
    }

    /// Missing or null fields take their defaults, as in the index files HomeClerk has written.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys, _ fallback: String = "") throws -> String {
            try c.decodeIfPresent(String.self, forKey: key) ?? fallback
        }
        documentType = try text(.documentType, "Other")
        area = try text(.area, "Other")
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        vendor = try text(.vendor)
        description = try text(.description)
        documentDate = try text(.documentDate)
        dueDate = try text(.dueDate)
        expiresOn = try text(.expiresOn)
        amount = try c.decodeIfPresent(Decimal.self, forKey: .amount)
        person = try text(.person)
        vehicle = try text(.vehicle)
        pet = try text(.pet)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(documentType, forKey: .documentType)
        try c.encode(area, forKey: .area)
        try c.encode(tags, forKey: .tags)
        try c.encode(vendor, forKey: .vendor)
        try c.encode(description, forKey: .description)
        try c.encode(documentDate, forKey: .documentDate)
        try c.encode(dueDate, forKey: .dueDate)
        try c.encode(expiresOn, forKey: .expiresOn)
        try c.encode(amount, forKey: .amount)
        try c.encode(person, forKey: .person)
        try c.encode(vehicle, forKey: .vehicle)
        try c.encode(pet, forKey: .pet)
    }
}
