import Foundation

public enum FieldStatus: String, Sendable { case pass = "Pass", fail = "Fail", notProduced = "NotProduced", verify = "Verify" }

public struct FieldResult: Sendable, Equatable {
    public var field: String
    public var expected: String
    public var actual: String
    public var status: FieldStatus
}

public struct CaseScore: Sendable {
    public var evalCase: EvalCase
    public var observed: ObservedFacts
    public var fields: [FieldResult]
    public var error: String?

    public var passed: Int { fields.filter { $0.status == .pass }.count }
    public var scored: Int { fields.filter { $0.status == .pass || $0.status == .fail }.count }
}

/// Compares observed facts to a case's expected facts, field by field.
public enum EvalScorer {
    public static let fieldOrder = ["folder", "area", "document_type", "tags", "vendor", "document_date", "amount",
                                    "person", "vehicle", "pet"]

    public static func score(_ c: EvalCase, _ observed: ObservedFacts, router: FilingRouter) -> CaseScore {
        let e = c.expected
        var results: [FieldResult] = []

        // The expected folder comes from routing the expected facets, so it tracks taxonomy.json.
        // Skipped while the facets that decide it are still unconfirmed.
        let folderDecidable = Set(c.verify).isDisjoint(with: ["folder", "area", "document_type"])
            && (e.area != nil || e.tags != nil)
        if folderDecidable {
            let expectedFolder = router.folder(for: DocumentFacets(documentType: e.documentType ?? "", area: e.area ?? "",
                                                                   tags: e.tags ?? []))
            results.append(compare("folder", expectedFolder, observed.folder,
                                   TextRules.equalsIgnoringCase(expectedFolder, observed.folder)))
        }

        addText(&results, "area", e.area, observed.area)
        addText(&results, "document_type", e.documentType, observed.documentType)
        if let tags = e.tags {
            if let observedTags = observed.tags {
                results.append(compare("tags", join(tags), join(observedTags),
                                       tags.allSatisfy { t in observedTags.contains { TextRules.equalsIgnoringCase($0, t) } }))
            } else {
                results.append(FieldResult(field: "tags", expected: join(tags), actual: "—", status: .notProduced))
            }
        }
        addText(&results, "vendor", e.vendor, observed.vendor)
        addText(&results, "document_date", e.documentDate, observed.documentDate, exact: true)
        if let amount = e.amount {
            let match = observed.amount.map { abs(NSDecimalNumber(decimal: $0 - amount).doubleValue) < 0.005 } ?? false
            results.append(compare("amount", TextRules.amount(amount), observed.amount.map(TextRules.amount) ?? "—", match))
        }
        addText(&results, "person", e.person, observed.person)
        addText(&results, "vehicle", e.vehicle, observed.vehicle)
        addText(&results, "pet", e.pet, observed.pet)

        // Unconfirmed fields: show what the analyzer found so a human can fill in the answer
        for field in c.verify where field != "folder" {
            results.append(FieldResult(field: field, expected: "?", actual: actual(field, observed), status: .verify))
        }

        let order = { (field: String) in fieldOrder.firstIndex(of: field) ?? -1 }
        results = results.enumerated().sorted { (order($0.element.field), $0.offset) < (order($1.element.field), $1.offset) }
            .map(\.element)
        return CaseScore(evalCase: c, observed: observed, fields: results, error: nil)
    }

    private static func addText(_ results: inout [FieldResult], _ field: String, _ expected: String?, _ actual: String?,
                                exact: Bool = false) {
        guard let expected else { return }
        guard let actual else {
            results.append(FieldResult(field: field, expected: expected, actual: "—", status: .notProduced))
            return
        }
        let match = exact ? expected == actual : TextRules.key(expected) == TextRules.key(actual)
        results.append(compare(field, expected, actual.isEmpty ? "(empty)" : actual, match))
    }

    private static func compare(_ field: String, _ expected: String, _ actual: String, _ match: Bool) -> FieldResult {
        FieldResult(field: field, expected: expected, actual: actual, status: match ? .pass : .fail)
    }

    static func join(_ tags: [String]) -> String { tags.joined(separator: ", ") }

    private static func actual(_ field: String, _ o: ObservedFacts) -> String {
        let value: String? = switch field {
        case "area": o.area
        case "document_type": o.documentType
        case "tags": o.tags.map(join)
        case "vendor": o.vendor
        case "document_date": o.documentDate
        case "amount": o.amount.map(TextRules.amount)
        case "person": o.person
        case "vehicle": o.vehicle
        case "pet": o.pet
        default: nil
        }
        return value.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
    }
}
