import Foundation

// MARK: - Your own rules

extension TaxonomyConfig {
    /// The rules in use: your copy in the HomeClerk folder (taxonomy.json) when there is one and it's
    /// valid, otherwise the ones built into the app. `problem` says why your copy wasn't used.
    public static func loadEffective(custom: URL, builtIn: URL) throws
        -> (config: TaxonomyConfig, usingCustom: Bool, problem: String?) {
        if FileManager.default.fileExists(atPath: custom.path) {
            do {
                return (try load(from: custom), true, nil)
            } catch {
                return (try load(from: builtIn), false, "\(error)")
            }
        }
        return (try load(from: builtIn), false, nil)
    }

    /// The rules as taxonomy.json, in the order HomeClerk reads them.
    public var json: JSONValue {
        func named(_ e: NamedEntry) -> JSONValue {
            .object([("name", .string(e.name))] + (e.description.isEmpty ? [] : [("description", .string(e.description))]))
        }
        return .object([
            ("documentTypes", .array(documentTypes.map(named))),
            ("areas", .array(areas.map(named))),
            ("suggestedTags", .object(suggestedTags.map { ($0.tag, .string($0.description)) })),
            ("rules", .array(rules.map { .object([("folder", .string($0.folder))] + $0.condition.pairs) })),
            ("fallbackFolder", .string(fallbackFolder)),
            ("includeAmountFor", .array(includeAmountFor.map { .object($0.pairs) })),
            ("retention", .array(retention.map { rule in
                .object([("when", .object(rule.condition.pairs)), ("keepYears", rule.keepYears.map { .number(Double($0)) } ?? .null),
                         ("reason", .string(rule.reason))])
            })),
            ("taxDocuments", .array(taxDocuments.map { .object($0.pairs) }))
        ])
    }

    /// Writes your copy, after checking it — an invalid taxonomy is never saved.
    public func save(to url: URL) throws {
        let errors = validate()
        guard errors.isEmpty else { throw InvalidError(description: errors.joined(separator: "\n")) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (json.pretty() + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

extension FacetCondition {
    /// Only the constraints that are present, as taxonomy.json writes them.
    var pairs: [(key: String, value: JSONValue)] {
        var out: [(key: String, value: JSONValue)] = []
        if let area { out.append(("area", .string(area))) }
        if let types { out.append(("types", .array(types.map(JSONValue.string)))) }
        if let tagsAny { out.append(("tagsAny", .array(tagsAny.map(JSONValue.string)))) }
        return out
    }
}

// MARK: - Applying changed rules to filed documents

/// A filed document the current rules would put elsewhere, or name differently.
public struct RefileMove: Identifiable, Equatable, Sendable {
    public var id: String { entry.path }
    public var entry: DocumentIndex.Entry
    public var fromFolder: String
    public var toFolder: String
    public var toName: String
}

extension ReviewActions {
    /// Where the rules in use would file each document now, for the ones that would move or be
    /// renamed. Nothing is re-read by a model: the details HomeClerk already has decide.
    public func refileMoves(_ documents: [DocumentIndex.Entry]) -> [RefileMove] {
        documents.compactMap { entry in
            let url = URL(fileURLWithPath: entry.path)
            guard FileOrganizer.isInside(url, settings.outboxFolder) else { return nil }
            let (folder, name) = destination(entry.facets)
            let current = url.deletingLastPathComponent().lastPathComponent
            let target = FileOrganizer.sanitizeFolder(folder)
            let targetName = FileOrganizer.sanitizeFile(name.lowercased().hasSuffix(".pdf") ? name : name + ".pdf")
            // "name_2.pdf" was named to avoid a clash; it already has the name the rules give
            let stem = url.deletingPathExtension().lastPathComponent.replacing(/_\d+$/, with: "")
            let sameName = url.lastPathComponent == targetName || stem + ".pdf" == targetName
            guard current != target || !sameName else { return nil }
            return RefileMove(entry: entry, fromFolder: current, toFolder: target, toName: targetName)
        }
        .sorted { ($0.toFolder, $0.toName) < ($1.toFolder, $1.toName) }
    }
}
