import Foundation

/// The sidecar files beside a scan in _review: "<scan>.reason.txt" says why it's there, and
/// "<scan>.proposal.json" holds the model's analysis so it can be filed as proposed. Same format
/// as HomeClerk has always written them, so scans already in review still file.
public enum ReviewProposal {
    public static func proposalURL(for scan: URL) -> URL {
        scan.deletingPathExtension().appendingPathExtension("proposal.json")
    }

    public static func reasonURL(for scan: URL) -> URL {
        scan.deletingPathExtension().appendingPathExtension("reason.txt")
    }

    public static func save(_ analysis: FacetAnalysis, for scan: URL) throws {
        try json(analysis).serialized.write(to: proposalURL(for: scan), atomically: true, encoding: .utf8)
    }

    public static func load(for scan: URL) -> FacetAnalysis? { load(from: proposalURL(for: scan)) }

    /// Reads an analysis in its JSON shape (PascalCase, facets in snake_case) — proposals and
    /// backfill's analysis cache both use it.
    static func load(from url: URL) -> FacetAnalysis? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let json = try? JSONValue(parsing: text) else { return nil }
        var analysis = FacetAnalysis(
            documents: (json["Documents"]?.arrayValue ?? []).compactMap { d in
                guard let facets = d["Facets"],
                      let decoded = try? JSONDecoder().decode(DocumentFacets.self, from: Data(facets.serialized.utf8))
                else { return nil }
                return FacetDocument(firstPage: d["FirstPage"]?.doubleValue.flatMap(Int.init(checking:)) ?? 1,
                                     lastPage: d["LastPage"]?.doubleValue.flatMap(Int.init(checking:)) ?? 1,
                                     facets: decoded, confidence: d["Confidence"]?.doubleValue ?? 0)
            },
            summary: json["Summary"]?.stringValue ?? "")
        analysis.model = json["Model"]?.stringValue ?? ""
        analysis.documentID = json["DocumentID"]?.stringValue
        analysis.usedFallback = json["UsedFallback"] == .bool(true)
        analysis.primaryError = json["PrimaryError"]?.stringValue
        return analysis
    }

    /// Removes the sidecar files once the scan has been dealt with.
    public static func deleteSidecars(for scan: URL) {
        try? FileManager.default.removeItem(at: proposalURL(for: scan))
        try? FileManager.default.removeItem(at: reasonURL(for: scan))
    }

    static func json(_ a: FacetAnalysis) throws -> JSONValue {
        func optional(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
        return .object([
            ("DocumentID", optional(a.documentID)),
            ("Documents", .array(try a.documents.map { d in
                .object([
                    ("FirstPage", .number(Double(d.firstPage))),
                    ("LastPage", .number(Double(d.lastPage))),
                    ("Facets", try JSONValue(parsing: String(decoding: JSONEncoder().encode(d.facets), as: UTF8.self))),
                    ("Confidence", .number(d.confidence))
                ])
            })),
            ("Summary", .string(a.summary)),
            ("Error", optional(a.error)),
            ("IsTransientFailure", .bool(a.isTransientFailure)),
            ("RetryAfterSeconds", .number(Double(a.retryAfterSeconds))),
            ("Model", .string(a.model)),
            ("UsedFallback", .bool(a.usedFallback)),
            ("PrimaryError", optional(a.primaryError))
        ])
    }
}
