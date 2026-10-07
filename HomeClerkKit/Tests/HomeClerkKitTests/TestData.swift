import Foundation
@testable import HomeClerkKit

/// Shared inputs: the shipped taxonomy.json (Resources/) and the reference fixtures.
enum TestData {
    /// The repository root, found from this file's location.
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let taxonomy: TaxonomyConfig = {
        try! TaxonomyConfig.load(from: repository.appendingPathComponent("Resources/taxonomy.json"))
    }()

    static func fixture(_ name: String) throws -> JSONValue {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
        return try JSONValue(parsing: String(contentsOf: url, encoding: .utf8))
    }

    static func facets(_ json: JSONValue) throws -> DocumentFacets {
        try JSONDecoder().decode(DocumentFacets.self, from: Data(json.serialized.utf8))
    }
}
