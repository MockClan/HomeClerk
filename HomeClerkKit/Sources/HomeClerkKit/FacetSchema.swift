import Foundation
import os

/// One document found in a scanned PDF.
public struct FacetDocument: Equatable, Sendable {
    public var firstPage: Int
    public var lastPage: Int
    public var facets: DocumentFacets
    public var confidence: Double

    public init(firstPage: Int, lastPage: Int, facets: DocumentFacets, confidence: Double) {
        self.firstPage = firstPage
        self.lastPage = lastPage
        self.facets = facets
        self.confidence = confidence
    }

    /// Every source page must belong to exactly one document before any parts are filed.
    /// Shared by automatic filing, manual splitting, and the Review form.
    public static func pageCoverageProblem(_ documents: [FacetDocument], pageCount: Int) -> String? {
        guard pageCount > 0 else { return "This scan has no readable pages" }
        guard !documents.isEmpty else { return "No documents were proposed for this scan" }
        var coveredThrough = 0
        for document in documents.sorted(by: { $0.firstPage < $1.firstPage }) {
            guard document.firstPage >= 1, document.lastPage <= pageCount else {
                return "Pages \(document.firstPage)–\(document.lastPage) aren't in this \(pageCount)-page scan"
            }
            guard document.lastPage >= document.firstPage else { return "A document ends before it starts" }
            if document.firstPage <= coveredThrough { return "Two documents share page \(document.firstPage)" }
            // Subtract before comparing to avoid overflow for malformed stored proposals.
            if document.firstPage - 1 > coveredThrough {
                let next = coveredThrough + 1
                return next == document.firstPage - 1 ? "Page \(next) isn't in any document"
                    : "Pages \(next)–\(document.firstPage - 1) aren't in any document"
            }
            coveredThrough = document.lastPage
        }
        if coveredThrough < pageCount {
            let next = coveredThrough + 1
            return next == pageCount ? "Page \(next) isn't in any document" : "Pages \(next)–\(pageCount) aren't in any document"
        }
        return nil
    }
}

/// The result of analyzing one PDF; it may describe several documents scanned together.
public struct FacetAnalysis: Equatable, Sendable {
    /// Existing document sent back to Review; absent for a newly imported scan or split parts.
    public var documentID: String?
    public var documents: [FacetDocument] = []
    /// The model's short description of the PDF and any judgment calls it made.
    public var summary = ""
    /// Set when analysis failed; `documents` is then empty.
    public var error: String?
    public var isTransientFailure = false
    public var retryAfterSeconds = 0
    /// The model that produced this analysis.
    public var model = ""
    /// True when the primary model failed and the fallback produced this result.
    public var usedFallback = false
    /// Why the primary model failed, when `usedFallback` is set.
    public var primaryError: String?

    public init(documents: [FacetDocument] = [], summary: String = "") {
        self.documents = documents
        self.summary = summary
    }

    public static func failed(_ error: String, transient: Bool = false, retryAfterSeconds: Int = 0) -> FacetAnalysis {
        var analysis = FacetAnalysis()
        analysis.error = error
        analysis.isTransientFailure = transient
        analysis.retryAfterSeconds = retryAfterSeconds
        return analysis
    }
}

/// The JSON schema every facet analyzer constrains its output to, and the shared reply parser.
/// Document type and area are enums sourced from taxonomy.json.
public enum FacetSchema {
    private static let noPrimaryTag = "none"
    private static let log = Logger(subsystem: "com.mockclan.homeclerk", category: "facets")

    /// - Parameter constrainTags: Limit tags to taxonomy.json's suggested list and add a required
    ///   primary_tag. Small local models pick far more reliably from an enum than from a vocabulary
    ///   described in prose, and leave optional lists empty unless a field forces a choice. Claude
    ///   handles free-form tags.
    public static func build(_ taxonomy: TaxonomyConfig, constrainTags: Bool = false) -> JSONValue {
        func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }
        let text: JSONValue = .object([("type", .string("string"))])
        let tagNames = taxonomy.suggestedTags.map(\.tag)
        let tagItem: JSONValue = constrainTags
            ? .object([("type", .string("string")), ("enum", strings(tagNames))])
            : text

        var leading: [(key: String, value: JSONValue)] = [
            ("first_page", .object([("type", .string("integer"))])),
            ("last_page", .object([("type", .string("integer"))]))
        ]
        // Models write fields in order. A small local model that names the sender and the document
        // first chooses its type, area, and tag from that, rather than committing to them blind
        // (it filed a water bill as a subscription, a gas bill as tolls). Claude's order is unchanged.
        if constrainTags { leading += [("vendor", text), ("description", text)] }
        leading += [
            ("document_type", .object([("type", .string("string")), ("enum", strings(taxonomy.documentTypes.map(\.name)))])),
            ("area", .object([("type", .string("string")), ("enum", strings(taxonomy.areas.map(\.name)))]))
        ]
        if constrainTags {
            leading.append(("primary_tag", .object([
                ("type", .string("string")),
                ("description", .string("The single suggested tag that best describes this document, or none")),
                ("enum", strings(tagNames + [noPrimaryTag]))
            ])))
        }
        let trailing: [(key: String, value: JSONValue)] = [
            ("tags", .object([("type", .string("array")), ("items", tagItem)])),
        ] + (constrainTags ? [] : [("vendor", text), ("description", text)]) + [
            ("document_date", text), ("due_date", text),
            ("expires_on", text),
            ("amount", .object([("anyOf", .array([.object([("type", .string("number"))]), .object([("type", .string("null"))])]))])),
            ("person", text), ("vehicle", text), ("pet", text),
            ("confidence", .object([("type", .string("number"))]))
        ]

        let document: JSONValue = .object([
            ("type", .string("object")),
            ("additionalProperties", .bool(false)),
            ("properties", .object(leading + trailing)),
            ("required", strings((leading + trailing).map(\.key)))
        ])

        // summary comes first so the model describes the document before committing to facts.
        // (Not named "reasoning": that reads as a request for the model's internal reasoning.)
        return .object([
            ("type", .string("object")),
            ("additionalProperties", .bool(false)),
            ("properties", .object([
                ("summary", .object([("type", .string("string"))])),
                ("documents", .object([("type", .string("array")), ("items", document)]))
            ])),
            ("required", strings(["summary", "documents"]))
        ])
    }

    /// Parses a schema-shaped reply, rejecting invalid page ranges and normalizing tags.
    public static func parse(_ json: String, pageCount: Int, modelName: String,
                             profile: HouseholdProfile? = nil) -> FacetAnalysis {
        do {
            let reply = try JSONValue(parsing: json)
            guard let items = reply["documents"]?.arrayValue, !items.isEmpty else {
                return .failed("\(modelName) returned no documents")
            }
            let documents = try items.map { item -> FacetDocument in
                // Facet fields share their JSON names with DocumentFacets, so each entry decodes into it directly
                var facets = try JSONDecoder().decode(DocumentFacets.self, from: Data(item.serialized.utf8))
                var tags = facets.tags
                if let primary = item["primary_tag"]?.stringValue, primary != noPrimaryTag {
                    tags.insert(primary, at: 0)
                }
                facets.tags = uniqued(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
                if let profile { facets = profile.canonicalize(facets) }

                // One document is the whole scan, whatever pages the model wrote — Apple's on-device
                // model sometimes writes nonsense such as 5337–5341 for a 5-page scan.
                if items.count == 1 {
                    return FacetDocument(firstPage: 1, lastPage: pageCount, facets: facets,
                                         confidence: min(max(item["confidence"]?.doubleValue ?? 0, 0), 1))
                }
                guard let firstNumber = item["first_page"]?.doubleValue,
                      let lastNumber = item["last_page"]?.doubleValue,
                      let first = Int(checking: firstNumber), let reportedLast = Int(checking: lastNumber),
                      Double(first) == firstNumber, Double(reportedLast) == lastNumber,
                      first >= 1, first <= pageCount, reportedLast >= first else {
                    throw PDFTools.Failure("Invalid page range in \(modelName)'s response for this \(pageCount)-page scan")
                }
                // Models often run a document's end past the scan's last page; that loses nothing,
                // so it's trimmed. Gaps and overlaps are still caught by pageCoverageProblem.
                let last = min(reportedLast, pageCount)
                return FacetDocument(firstPage: first, lastPage: last, facets: facets,
                                     confidence: min(max(item["confidence"]?.doubleValue ?? 0, 0), 1))
            }
            return FacetAnalysis(documents: documents, summary: reply["summary"]?.stringValue ?? "")
        } catch {
            log.warning("Could not parse \(modelName, privacy: .public) facets: \(error.localizedDescription)")
            return .failed("Unparseable response from \(modelName): \(error)")
        }
    }

    private static func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
