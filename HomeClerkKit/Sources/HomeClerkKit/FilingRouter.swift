import Foundation

/// Maps document facets to a folder name using the taxonomy's ordered rules.
public struct FilingRouter: Sendable {
    public let config: TaxonomyConfig

    public init(_ config: TaxonomyConfig) { self.config = config }

    public func folder(for facets: DocumentFacets) -> String {
        if let rule = config.rules.first(where: { $0.matches(facets) }) { return rule.folder }
        let area = facets.area.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Other" : facets.area
        return config.fallbackFolder.replacingOccurrences(of: "{area}", with: area, options: .caseInsensitive)
    }
}
