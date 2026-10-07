import Foundation
import Testing
@testable import HomeClerkKit

/// Returns queued results in order and counts calls.
final class FakeAnalyzer: FacetAnalyzer, @unchecked Sendable {
    let modelName: String
    let isPaid = false
    private var results: [FacetAnalysis]
    private(set) var calls = 0

    init(_ name: String, _ results: FacetAnalysis...) {
        modelName = name
        self.results = results
    }

    func analyze(ocrText: String, pageCount: Int, pdf: URL) async -> FacetAnalysis {
        calls += 1
        return results.removeFirst()
    }
}

@Suite struct ResilientFacetAnalyzerTests {
    static func success(_ vendor: String) -> FacetAnalysis {
        FacetAnalysis(documents: [FacetDocument(firstPage: 1, lastPage: 1, facets: DocumentFacets(vendor: vendor), confidence: 0.9)])
    }

    func analyze(_ primary: FakeAnalyzer, _ fallback: FakeAnalyzer?) async -> FacetAnalysis {
        await ResilientFacetAnalyzer(primary: primary, fallback: fallback, delay: { _ in })
            .analyze(ocrText: "text", pageCount: 1, pdf: URL(fileURLWithPath: "/x.pdf"))
    }

    @Test func primarySuccessSkipsFallback() async {
        let fallback = FakeAnalyzer("local")
        let result = await analyze(FakeAnalyzer("cloud", Self.success("Acme")), fallback)
        #expect(result.error == nil && result.model == "cloud" && !result.usedFallback && fallback.calls == 0)
    }

    @Test func retriesTransientFailuresBeforeFallingBack() async {
        let primary = FakeAnalyzer("cloud", .failed("rate limit", transient: true), .failed("server error", transient: true),
                                   Self.success("Acme"))
        let fallback = FakeAnalyzer("local")
        let result = await analyze(primary, fallback)
        #expect(primary.calls == 3 && fallback.calls == 0 && result.model == "cloud")
    }

    @Test func permanentFailureFallsBackWithoutRetrying() async {
        let primary = FakeAnalyzer("cloud", .failed("credit balance is too low"))
        let result = await analyze(primary, FakeAnalyzer("local", Self.success("Acme")))
        #expect(primary.calls == 1)
        #expect(result.error == nil && result.usedFallback && result.model == "local")
        #expect(result.primaryError == "credit balance is too low")
    }

    @Test func reportsEachEngineAsItStarts() async {
        let started = Locked<[String]>([])
        _ = await ResilientFacetAnalyzer(primary: FakeAnalyzer("cloud", .failed("refused")),
                                         fallback: FakeAnalyzer("local", Self.success("Acme")), delay: { _ in },
                                         onAnalyzing: { pdf, model in started.mutate { $0.append("\(pdf.lastPathComponent):\(model)") } })
            .analyze(ocrText: "text", pageCount: 1, pdf: URL(fileURLWithPath: "/scan.pdf"))
        #expect(started.value == ["scan.pdf:cloud", "scan.pdf:local"])
    }

    @Test func reportsBothErrorsWhenFallbackAlsoFails() async {
        let result = await analyze(FakeAnalyzer("cloud", .failed("refused")), FakeAnalyzer("local", .failed("not reachable")))
        #expect(result.error?.contains("cloud: refused") == true)
        #expect(result.error?.contains("local: not reachable") == true)
    }

    @Test func withoutFallbackTheFailureIsReturned() async {
        let result = await analyze(FakeAnalyzer("cloud", .failed("refused")), nil)
        #expect(result.error == "refused" && !result.usedFallback)
    }
}

final class Locked<T>: @unchecked Sendable {
    private var stored: T
    private let lock = NSLock()
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func mutate(_ change: (inout T) -> Void) { lock.withLock { change(&stored) } }
}

@Suite struct ClaudeFacetAnalyzerTests {
    let ledgerURL = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID()).jsonl")

    func analyzer(sendPDF: Bool = true) -> ClaudeFacetAnalyzer {
        ClaudeFacetAnalyzer(apiKey: "test", model: "claude-sonnet-5-5", effort: "medium", sendPDF: sendPDF,
                            taxonomy: TestData.taxonomy, profile: .empty, ledger: UsageLedger(url: ledgerURL))
    }

    func reply(_ stopReason: String, text: String? = nil, extra: String = "") -> Data {
        let content = text.map { #"[{"type":"text","text":\#(JSONValue.string($0).serialized)}]"# } ?? "[]"
        return Data(#"""
            {"model":"claude-sonnet-5-5","stop_reason":"\#(stopReason)","content":\#(content)\#(extra),
             "usage":{"input_tokens":5508,"output_tokens":278,"cache_creation_input_tokens":4771,"cache_read_input_tokens":0}}
            """#.utf8)
    }

    static let facets = #"{"summary":"A bill.","documents":[{"first_page":1,"last_page":1,"document_type":"Bill","area":"Utilities","tags":[],"vendor":"Acme Power","description":"Electric_Bill","document_date":"2026-02-03","due_date":"","expires_on":"","amount":88.12,"person":"","vehicle":"","pet":"","confidence":0.95}]}"#

    @Test func requestFollowsTheDocumentedShape() throws {
        let pdf = FileManager.default.temporaryDirectory.appendingPathComponent("tiny-\(UUID()).pdf")
        try Data("%PDF-1.4 tiny".utf8).write(to: pdf)
        defer { try? FileManager.default.removeItem(at: pdf) }

        let body = try analyzer().requestBody(ocrText: "Acme Power", pageCount: 1, pdf: pdf)
        #expect(body.objectPairs?.map(\.key) == ["model", "max_tokens", "fallbacks", "system", "output_config", "messages"])
        #expect(body["fallbacks"] == .string("default"))
        #expect(body["system"]?.arrayValue?.first?["cache_control"] == .object([("type", .string("ephemeral"))]))
        #expect(body["output_config"]?["effort"] == .string("medium"))
        #expect(body["output_config"]?["format"]?["type"] == .string("json_schema"))
        #expect(body["output_config"]?["format"]?["schema"] == FacetSchema.build(TestData.taxonomy))
        let content = body["messages"]?.arrayValue?.first?["content"]?.arrayValue ?? []
        #expect(content.map { $0["type"]?.stringValue } == ["document", "text"])
        #expect(content[0]["source"]?["media_type"] == .string("application/pdf"))
        #expect(content[0]["source"]?["data"] == .string(Data("%PDF-1.4 tiny".utf8).base64EncodedString()))
    }

    @Test func withoutPageImagesOnlyTextIsSent() throws {
        let body = try analyzer(sendPDF: false).requestBody(ocrText: "x", pageCount: 1, pdf: URL(fileURLWithPath: "/missing.pdf"))
        #expect(body["messages"]?.arrayValue?.first?["content"]?.arrayValue?.map { $0["type"]?.stringValue } == ["text"])
    }

    @Test func parsesAnswerAndRecordsUsage() throws {
        let result = analyzer().interpret(status: 200, body: reply("end_turn", text: Self.facets), retryAfter: nil, pageCount: 1)
        #expect(result.error == nil)
        #expect(result.documents.first?.facets.vendor == "Acme Power")
        let entries = try UsageLedger.load(from: ledgerURL)
        #expect(entries.count == 1 && entries[0].input == 5508 && entries[0].cacheWrite == 4771)
        try? FileManager.default.removeItem(at: ledgerURL)
    }

    @Test func readsOnlyTextBlocksWhenAFallbackServedTheAnswer() {
        let content = #"[{"type":"fallback","from":{"model":"claude-sonnet-5-5"},"to":{"model":"claude-sonnet-5"}},{"type":"text","text":\#(JSONValue.string(Self.facets).serialized)}]"#
        let body = Data(#"{"model":"claude-sonnet-5","stop_reason":"end_turn","content":\#(content),"usage":{}}"#.utf8)
        #expect(analyzer().interpret(status: 200, body: body, retryAfter: nil, pageCount: 1).error == nil)
        try? FileManager.default.removeItem(at: ledgerURL)
    }

    @Test func refusalIsAFailureWithItsCategory() {
        let result = analyzer().interpret(status: 200, body: reply("refusal", extra: #","stop_details":{"type":"refusal","category":"bio"}"#),
                                          retryAfter: nil, pageCount: 1)
        #expect(result.error == "Claude declined to analyze this document (bio)")
        #expect(!result.isTransientFailure)
        try? FileManager.default.removeItem(at: ledgerURL)
    }

    @Test func cutOffResponseIsAFailure() {
        #expect(analyzer().interpret(status: 200, body: reply("max_tokens", text: "{"), retryAfter: nil, pageCount: 1).error
                == "Claude's response was cut off (max_tokens)")
        try? FileManager.default.removeItem(at: ledgerURL)
    }

    @Test func rateLimitUsesRetryAfter() {
        let result = analyzer().interpret(status: 429, body: Data(), retryAfter: "12", pageCount: 1)
        #expect(result.isTransientFailure && result.retryAfterSeconds == 12)
        #expect(analyzer().interpret(status: 429, body: Data(), retryAfter: nil, pageCount: 1).retryAfterSeconds == 65)
    }

    @Test func overloadedAndServerErrorsAreTransient() {
        #expect(analyzer().interpret(status: 529, body: Data(), retryAfter: nil, pageCount: 1).isTransientFailure)
        #expect(analyzer().interpret(status: 500, body: Data(), retryAfter: nil, pageCount: 1).isTransientFailure)
    }

    @Test func clientErrorsAreFinalAndCarryTheMessage() {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"credit balance is too low"}}"#.utf8)
        let result = analyzer().interpret(status: 400, body: body, retryAfter: nil, pageCount: 1)
        #expect(!result.isTransientFailure)
        #expect(result.error == "Claude API error 400: credit balance is too low")
    }
}

@Suite struct OllamaFacetAnalyzerTests {
    @Test func requestUsesTheConstrainedSchemaAndDeterministicSampling() throws {
        let analyzer = OllamaFacetAnalyzer(baseURL: URL(string: "http://localhost:11434")!, model: "qwen3-vl:8b-instruct",
                                           sendImages: false, maxImagePages: 2, taxonomy: TestData.taxonomy, profile: .empty)
        let body = try analyzer.requestBody(ocrText: "x", pageCount: 1, pdf: URL(fileURLWithPath: "/missing.pdf"))
        #expect(body["format"] == FacetSchema.build(TestData.taxonomy, constrainTags: true))
        #expect(body["options"]?["temperature"] == .number(0))
        #expect(body["stream"] == .bool(false))
        #expect(body["messages"]?.arrayValue?.map { $0["role"]?.stringValue } == ["system", "user"])
    }
}

@Suite struct AppleFacetAnalyzerTests {
    @Test func zeroAmountMeansNone() throws {
        let json = AppleFacetAnalyzer.nullZeroAmounts(#"{"summary":"s","documents":[{"amount":0},{"amount":12.5}]}"#)
        let documents = try JSONValue(parsing: json)["documents"]?.arrayValue
        #expect(documents?[0]["amount"] == .null)
        #expect(documents?[1]["amount"] == .number(12.5))
    }

    @Test func noneMeansNoOneInParticular() throws {
        let json = AppleFacetAnalyzer.nullZeroAmounts(
            #"{"summary":"s","documents":[{"amount":5,"person":"none","vehicle":"none","pet":"Biscuit"}]}"#)
        let document = try JSONValue(parsing: json)["documents"]?.arrayValue?.first
        #expect(document?["person"] == .string("") && document?["vehicle"] == .string(""))
        #expect(document?["pet"] == .string("Biscuit"))
        #expect(AppleFacetAnalyzer.unique(["Jane_Smith", "", "none", "Jane_Smith", "Sam_Smith"]) == ["Jane_Smith", "Sam_Smith"])
    }
}
