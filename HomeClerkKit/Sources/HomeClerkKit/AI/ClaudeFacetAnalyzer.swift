import Foundation
import os

/// Extracts document facets with Claude over the Messages API. Sends the scanned PDF (so Claude
/// sees the page images) plus the Vision OCR text, and constrains the reply with structured
/// outputs so the document type and area can only be values from taxonomy.json. The system
/// prompt is built once and cached; only the PDF and OCR text change per request.
///
/// Swift has no official Anthropic SDK, so this speaks the documented HTTP API directly.
public struct ClaudeFacetAnalyzer: FacetAnalyzer {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// `fallbacks: "default"`: if a safety classifier declines a document, the server retries it
    /// on the model Anthropic recommends for that refusal category.
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    public let model: String
    public let effort: String
    public let sendPDF: Bool
    let apiKey: String
    let profile: HouseholdProfile
    let systemPrompt: String
    let schema: JSONValue
    let ledger: UsageLedger?
    let session: URLSession
    private let log = Logger(subsystem: "com.mockclan.homeclerk", category: "claude")

    public init(apiKey: String, model: String, effort: String, sendPDF: Bool, taxonomy: TaxonomyConfig,
                profile: HouseholdProfile, ledger: UsageLedger?, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.sendPDF = sendPDF
        self.profile = profile
        self.ledger = ledger
        self.session = session
        systemPrompt = FacetPrompt.buildSystem(taxonomy, profile)
        schema = FacetSchema.build(taxonomy)
    }

    public var modelName: String { "Claude \(model)" }
    public var isPaid: Bool { true }

    /// The request body, exposed so tests can check its shape without calling the API.
    func requestBody(ocrText: String, pageCount: Int, pdf: URL) throws -> JSONValue {
        var content: [JSONValue] = []
        if sendPDF {
            content.append(.object([
                ("type", .string("document")),
                ("source", .object([
                    ("type", .string("base64")),
                    ("media_type", .string("application/pdf")),
                    ("data", .string(try Data(contentsOf: pdf).base64EncodedString()))
                ]))
            ]))
        }
        content.append(.object([("type", .string("text")),
                                ("text", .string(FacetPrompt.buildUserText(ocrText: ocrText, pageCount: pageCount)))]))
        return .object([
            ("model", .string(model)),
            ("max_tokens", .number(16000)),
            ("fallbacks", .string("default")),
            ("system", .array([.object([
                ("type", .string("text")),
                ("text", .string(systemPrompt)),
                ("cache_control", .object([("type", .string("ephemeral"))]))
            ])])),
            ("output_config", .object([
                ("effort", .string(effort)),
                ("format", .object([("type", .string("json_schema")), ("schema", schema)]))
            ])),
            ("messages", .array([.object([("role", .string("user")), ("content", .array(content))])]))
        ])
    }

    public func analyze(ocrText: String, pageCount: Int, pdf: URL) async -> FacetAnalysis {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")

        let data: Data, response: HTTPURLResponse
        do {
            request.httpBody = Data(try requestBody(ocrText: ocrText, pageCount: pageCount, pdf: pdf).serialized.utf8)
            let (body, urlResponse) = try await session.data(for: request)
            data = body
            guard let http = urlResponse as? HTTPURLResponse else { return .failed("Claude sent back something that isn't an HTTP response") }
            response = http
        } catch let error as URLError where error.code == .cancelled {
            return .failed("Cancelled")
        } catch let error as URLError {
            log.error("Claude request failed: \(error.localizedDescription, privacy: .private)")
            return .failed("Request failed: \(error.localizedDescription)", transient: true)
        } catch {
            return .failed("Claude analysis failed: \(error)")
        }
        return interpret(status: response.statusCode, body: data,
                         retryAfter: response.value(forHTTPHeaderField: "retry-after"), pageCount: pageCount)
    }

    /// Turns an HTTP response into an analysis; separate from the call so it can be tested.
    func interpret(status: Int, body: Data, retryAfter: String?, pageCount: Int) -> FacetAnalysis {
        let reply = try? JSONValue(parsing: String(decoding: body, as: UTF8.self))
        guard status == 200 else {
            let message = reply?["error"]?["message"]?.stringValue ?? "HTTP \(status)"
            switch status {
            case 429:
                log.warning("Claude rate limit hit")
                // retry-after is in seconds; without it, wait out the one-minute rate-limit window
                return .failed("Claude rate limit", transient: true, retryAfterSeconds: retryAfter.flatMap { Int($0) } ?? 65)
            case 500...:
                // 5xx, including 529 overloaded
                log.error("Claude server error \(status)")
                return .failed("Claude server error \(status)", transient: true)
            default:
                log.error("Claude API error \(status): \(message, privacy: .private)")
                return .failed("Claude API error \(status): \(message)")
            }
        }
        guard let reply else { return .failed("Unparseable response from Claude") }

        let usage = reply["usage"]
        func tokens(_ key: String) -> Int { usage?[key]?.doubleValue.flatMap(Int.init(checking:)) ?? 0 }
        let servedBy = reply["model"]?.stringValue ?? model
        ledger?.record(model: servedBy, input: tokens("input_tokens"), output: tokens("output_tokens"),
                       cacheWrite: tokens("cache_creation_input_tokens"), cacheRead: tokens("cache_read_input_tokens"))

        // Check stop_reason before reading content: a refusal can arrive with no content at all
        switch reply["stop_reason"]?.stringValue {
        case "refusal":
            let category = reply["stop_details"]?["category"]?.stringValue ?? "no category"
            return .failed("Claude declined to analyze this document (\(category))")
        case "max_tokens":
            return .failed("Claude's response was cut off (max_tokens)")
        default:
            break
        }

        // Only text blocks carry the answer; a fallback switch adds a "fallback" block
        let json = (reply["content"]?.arrayValue ?? [])
            .filter { $0["type"]?.stringValue == "text" }
            .compactMap { $0["text"]?.stringValue }
            .joined()
        return FacetSchema.parse(json, pageCount: pageCount, modelName: "Claude", profile: profile)
    }
}
