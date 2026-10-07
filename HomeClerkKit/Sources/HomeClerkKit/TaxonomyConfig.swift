import Foundation

/// The household filing configuration from taxonomy.json: the closed lists the AI chooses from
/// (document types, areas), a suggested tag vocabulary, and the ordered rules that turn facets
/// into a folder.
public struct TaxonomyConfig: Sendable {
    public static let fileName = "taxonomy.json"

    public var documentTypes: [NamedEntry] = []
    public var areas: [NamedEntry] = []
    /// Tag and description, in file order. The AI prefers these but may add new tags.
    public var suggestedTags: [(tag: String, description: String)] = []
    /// Evaluated in order; the first matching rule decides the folder.
    public var rules: [FilingRule] = []
    /// Folder when no rule matches. "{area}" is replaced with the document's area.
    public var fallbackFolder = "{area}"
    /// Documents matching any of these conditions get the amount appended to the file name.
    public var includeAmountFor: [FacetCondition] = []
    /// How long to keep each kind of document; the first matching rule applies. Unmatched documents
    /// are kept indefinitely.
    public var retention: [RetentionRule] = []
    /// What goes in a tax-year export, besides documents in the "Taxes" area.
    public var taxDocuments: [FacetCondition] = []

    public init(documentTypes: [NamedEntry] = [], areas: [NamedEntry] = [],
                suggestedTags: [(tag: String, description: String)] = [], rules: [FilingRule] = [],
                fallbackFolder: String = "{area}", includeAmountFor: [FacetCondition] = []) {
        self.documentTypes = documentTypes
        self.areas = areas
        self.suggestedTags = suggestedTags
        self.rules = rules
        self.fallbackFolder = fallbackFolder
        self.includeAmountFor = includeAmountFor
    }

    public struct InvalidError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Loads and validates a taxonomy file; the error lists every problem.
    public static func load(from url: URL) throws -> TaxonomyConfig {
        let json = try JSONValue(parsing: String(contentsOf: url, encoding: .utf8))
        let config = TaxonomyConfig(json: json)
        let errors = config.validate()
        guard errors.isEmpty else {
            throw InvalidError(description: "\(url.path) is invalid:\n  " + errors.joined(separator: "\n  "))
        }
        return config
    }

    init(json: JSONValue) {
        documentTypes = json["documentTypes"]?.arrayValue?.map(NamedEntry.init(json:)) ?? []
        areas = json["areas"]?.arrayValue?.map(NamedEntry.init(json:)) ?? []
        suggestedTags = json["suggestedTags"]?.objectPairs?.map { ($0.key, $0.value.stringValue ?? "") } ?? []
        rules = json["rules"]?.arrayValue?.map(FilingRule.init(json:)) ?? []
        fallbackFolder = json["fallbackFolder"]?.stringValue ?? "{area}"
        includeAmountFor = json["includeAmountFor"]?.arrayValue?.map(FacetCondition.init(json:)) ?? []
        retention = json["retention"]?.arrayValue?.map(RetentionRule.init(json:)) ?? []
        taxDocuments = json["taxDocuments"]?.arrayValue?.map(FacetCondition.init(json:)) ?? []
    }

    public func isDocumentType(_ name: String) -> Bool {
        documentTypes.contains { TextRules.equalsIgnoringCase($0.name, name) }
    }

    public func isArea(_ name: String) -> Bool {
        areas.contains { TextRules.equalsIgnoringCase($0.name, name) }
    }

    public func validate() -> [String] {
        var errors: [String] = []
        if documentTypes.isEmpty { errors.append("documentTypes is empty") }
        if areas.isEmpty { errors.append("areas is empty") }
        if !isArea("Other") { errors.append("areas must include \"Other\"") }
        if !isDocumentType("Other") { errors.append("documentTypes must include \"Other\"") }

        let conditions = rules.enumerated().map { ("rules[\($0.offset)] (\($0.element.folder))", $0.element.condition) }
            + includeAmountFor.enumerated().map { ("includeAmountFor[\($0.offset)]", $0.element) }
            + retention.enumerated().map { ("retention[\($0.offset)]", $0.element.condition) }
            + taxDocuments.enumerated().map { ("taxDocuments[\($0.offset)]", $0.element) }
        for (label, condition) in conditions {
            if let area = condition.area, !isArea(area) {
                errors.append("\(label): unknown area \"\(area)\"")
            }
            for type in condition.types ?? [] where !isDocumentType(type) {
                errors.append("\(label): unknown document type \"\(type)\"")
            }
        }

        for (i, rule) in rules.enumerated() where rule.folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("rules[\(i)]: folder is empty")
        }
        return errors
    }
}

public struct NamedEntry: Equatable, Sendable {
    public var name: String
    public var description: String

    public init(name: String, description: String = "") {
        self.name = name
        self.description = description
    }

    init(json: JSONValue) {
        name = json["name"]?.stringValue ?? ""
        description = json["description"]?.stringValue ?? ""
    }
}

/// A set of facet constraints; every constraint that's present must hold. An empty condition
/// matches everything.
public struct FacetCondition: Equatable, Sendable {
    public var area: String?
    /// Document type must be one of these.
    public var types: [String]?
    /// Document must carry at least one of these tags.
    public var tagsAny: [String]?

    public init(area: String? = nil, types: [String]? = nil, tagsAny: [String]? = nil) {
        self.area = area
        self.types = types
        self.tagsAny = tagsAny
    }

    init(json: JSONValue) {
        area = json["area"]?.stringValue
        types = json["types"]?.stringArray
        tagsAny = json["tagsAny"]?.stringArray
    }

    public func matches(_ facets: DocumentFacets) -> Bool {
        (area.map { TextRules.equalsIgnoringCase($0, facets.area) } ?? true)
            && (types.map { $0.contains { TextRules.equalsIgnoringCase($0, facets.documentType) } } ?? true)
            && (tagsAny.map { $0.contains(where: facets.hasTag) } ?? true)
    }
}

/// How long to keep documents matching a condition; nil years means keep indefinitely.
public struct RetentionRule: Equatable, Sendable {
    public var condition: FacetCondition
    public var keepYears: Int?
    public var reason: String

    public init(condition: FacetCondition, keepYears: Int?, reason: String = "") {
        self.condition = condition
        self.keepYears = keepYears
        self.reason = reason
    }

    init(json: JSONValue) {
        condition = json["when"].map(FacetCondition.init(json:)) ?? FacetCondition()
        keepYears = json["keepYears"]?.doubleValue.flatMap(Int.init(checking:))
        reason = json["reason"]?.stringValue ?? ""
    }
}

public struct FilingRule: Equatable, Sendable {
    public var folder: String
    public var condition: FacetCondition

    public init(folder: String, condition: FacetCondition = FacetCondition()) {
        self.folder = folder
        self.condition = condition
    }

    init(json: JSONValue) {
        folder = json["folder"]?.stringValue ?? ""
        condition = FacetCondition(json: json)
    }

    public func matches(_ facets: DocumentFacets) -> Bool { condition.matches(facets) }
}
