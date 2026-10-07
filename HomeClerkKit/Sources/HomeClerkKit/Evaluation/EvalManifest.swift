import Foundation

/// The accuracy test set: expected.json plus the scans/ folder beside it. Lives outside the
/// repository (default ~/HomeClerk-TestData, or ~/DocuSort-TestData from before the rename)
/// because it holds personal documents.
public struct EvalManifest: Sendable {
    public static let fileName = "expected.json"
    public static var defaultDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let current = home.appendingPathComponent("HomeClerk-TestData"), legacy = home.appendingPathComponent(Legacy.testDataFolder)
        return !FileManager.default.fileExists(atPath: current.path) && FileManager.default.fileExists(atPath: legacy.path) ? legacy : current
    }

    public var cases: [EvalCase]
    public let directory: URL

    public static func load(from directory: URL) throws -> EvalManifest {
        let json = try JSONValue(parsing: String(contentsOf: directory.appendingPathComponent(fileName), encoding: .utf8))
        return EvalManifest(cases: (json["cases"]?.arrayValue ?? []).map(EvalCase.init(json:)), directory: directory)
    }

    public func scanURL(_ c: EvalCase) -> URL { directory.appendingPathComponent("scans").appendingPathComponent(c.scan) }
    public func ocrCacheURL(_ c: EvalCase) -> URL {
        directory.appendingPathComponent("cache/ocr").appendingPathComponent("\(c.sha256).json")
    }
}

public struct EvalCase: Sendable {
    public var id: String
    public var scan: String
    public var why: String
    public var sha256: String
    /// Only the fields present here are scored.
    public var expected: ExpectedFacts
    /// Fields a human still has to confirm; reported but never scored.
    public var verify: [String]

    init(json: JSONValue) {
        id = json["id"]?.stringValue ?? ""
        scan = json["scan"]?.stringValue ?? ""
        why = json["why"]?.stringValue ?? ""
        sha256 = json["sha256"]?.stringValue ?? ""
        expected = ExpectedFacts(json: json["expected"] ?? .object([]))
        verify = json["verify"]?.stringArray ?? []
    }

    public init(id: String, expected: ExpectedFacts, verify: [String] = []) {
        self.id = id
        scan = ""
        why = ""
        sha256 = ""
        self.expected = expected
        self.verify = verify
    }
}

/// Expected facet values; nil means "not specified, don't score".
public struct ExpectedFacts: Sendable {
    public var area, documentType, vendor, description, documentDate, person, vehicle, pet: String?
    public var tags: [String]?
    public var amount: Decimal?

    public init(area: String? = nil, documentType: String? = nil, tags: [String]? = nil, vendor: String? = nil,
                documentDate: String? = nil, amount: Decimal? = nil, person: String? = nil,
                vehicle: String? = nil, pet: String? = nil) {
        self.area = area
        self.documentType = documentType
        self.tags = tags
        self.vendor = vendor
        self.documentDate = documentDate
        self.amount = amount
        self.person = person
        self.vehicle = vehicle
        self.pet = pet
    }

    init(json: JSONValue) {
        area = json["area"]?.stringValue
        documentType = json["document_type"]?.stringValue
        tags = json["tags"]?.stringArray
        vendor = json["vendor"]?.stringValue
        description = json["description"]?.stringValue
        documentDate = json["document_date"]?.stringValue
        amount = json["amount"]?.doubleValue.map { Decimal(string: String($0)) ?? Decimal($0) }
        person = json["person"]?.stringValue
        vehicle = json["vehicle"]?.stringValue
        pet = json["pet"]?.stringValue
    }
}

/// What an analyzer produced for one document, in a shape the scorer can compare.
public struct ObservedFacts: Sendable, Encodable {
    public var folder = ""
    public var filename = ""
    public var confidence = 0.0
    public var splitCount = 0
    public var reasoning = ""
    public var area, documentType, vendor, description, documentDate, person, vehicle, pet: String?
    public var tags: [String]?
    public var amount: Decimal?

    public init() {}

    public init(facets: DocumentFacets, router: FilingRouter, names: FilenameBuilder, confidence: Double,
                splitCount: Int, reasoning: String) {
        folder = router.folder(for: facets)
        filename = names.build(facets)
        self.confidence = confidence
        self.splitCount = splitCount
        self.reasoning = reasoning
        area = facets.area
        documentType = facets.documentType
        tags = facets.tags
        vendor = facets.vendor
        description = facets.description
        documentDate = facets.documentDate
        amount = facets.amount
        person = facets.person
        vehicle = facets.vehicle
        pet = facets.pet
    }
}
