import Foundation
import Testing
@testable import HomeClerkKit

@Suite struct OllamaModelsTests {
    static let gb: UInt64 = 1_000_000_000

    @Test func recommendsTheMostAccurateModelThatFitsComfortably() {
        #expect(OllamaCatalog.recommendation(memory: 8 * Self.gb).name == "qwen3-vl:2b-instruct")
        #expect(OllamaCatalog.recommendation(memory: 16 * Self.gb).name == "qwen3-vl:8b-instruct")
        #expect(OllamaCatalog.recommendation(memory: 64 * Self.gb).name == "qwen3-vl:30b-a3b-instruct")
    }

    @Test func fitComparesWhatTheModelNeedsWithTheMacsMemory() {
        let eightB: Int64 = 6_100_000_000
        #expect(OllamaCatalog.fit(eightB, memory: 32 * Self.gb) == .comfortable)
        #expect(OllamaCatalog.fit(eightB, memory: 12 * Self.gb) == .tight)
        #expect(OllamaCatalog.fit(eightB, memory: 8 * Self.gb) == .tooBig)
    }

    @Test func readsTagsAndCapabilities() throws {
        let tags = try JSONValue(parsing: """
            {"models":[{"name":"qwen3-vl:8b-instruct","size":6100000000,"details":{"parameter_size":"8.8B","families":["qwen3vl"]}}]}
            """)
        #expect(OllamaCatalog.models(fromTags: tags) == [OllamaModelInfo(name: "qwen3-vl:8b-instruct", sizeBytes: 6_100_000_000,
                                                                       parameterSize: "8.8B")])
        #expect(OllamaCatalog.readsImages(fromShow: try JSONValue(parsing: #"{"capabilities":["completion","vision"]}"#)) == true)
        #expect(OllamaCatalog.readsImages(fromShow: try JSONValue(parsing: #"{"capabilities":["completion"]}"#)) == false)
        #expect(OllamaCatalog.readsImages(fromShow: try JSONValue(parsing: #"{"details":{"families":["llama","clip"]}}"#)) == true)
        #expect(OllamaCatalog.readsImages(fromShow: try JSONValue(parsing: #"{"details":{}}"#)) == nil)
    }

    @Test func trackRecordCountsWhatNeededYou() {
        func entry(_ model: String, source: String = "scan.pdf", corrected: Bool = false) -> DocumentIndex.Entry {
            var e = DocumentIndex.Entry(path: "/x/\(UUID()).pdf", source: source, pages: [1, 1], model: model, confidence: 0.9,
                                        summary: "", facets: DocumentFacets())
            e.corrected = corrected
            return e
        }
        let documents = [entry("Ollama qwen3-vl:8b-instruct"), entry("Ollama qwen3-vl:8b-instruct"),
                         entry("Ollama qwen3-vl:8b-instruct", source: "review:a.pdf"),
                         entry("Ollama qwen3-vl:8b-instruct", corrected: true), entry("Claude claude-sonnet-5-5")]
        let record = ModelTrackRecord.of("qwen3-vl:8b-instruct", in: documents, pendingInReview: 1)
        #expect(record.analyzed == 5 && record.filedOnItsOwn == 2)
        #expect(record.share == 0.4)
        #expect(ModelTrackRecord.of("qwen3-vl:2b-instruct", in: documents).share == nil)
    }

    @Test func correctedIsWrittenOnlyWhenTrue() throws {
        let temp = TempFolder()
        let index = DocumentIndex(url: temp.url.appendingPathComponent("index.jsonl"))
        var entry = DocumentIndex.Entry(path: "/a.pdf", source: "s", pages: [], model: "m", confidence: 1, summary: "",
                                        facets: DocumentFacets())
        try index.append(entry)
        entry.corrected = true
        try index.append(entry)
        let lines = try String(contentsOf: index.url, encoding: .utf8).split(separator: "\n")
        #expect(!lines[0].contains("corrected") && lines[1].contains("\"corrected\":true"))
        #expect(index.load().map(\.corrected) == [false, true])
    }
}

@Suite struct OllamaUnloadTests {
    @Test func keepAliveFollowsTheSetting() {
        #expect(OllamaFacetAnalyzer.keepAlive(minutes: 5) == .string("5m"))
        #expect(OllamaFacetAnalyzer.keepAlive(minutes: -1) == .number(-1))
        #expect(HomeClerkSettings().ollamaUnloadMinutes == 5)
        #expect(HomeClerkSettings(values: ["OllamaUnloadMinutes": .number(30)]).ollamaUnloadMinutes == 30)
        #expect(HomeClerkSettings(values: ["OllamaUnloadMinutes": .number(-7)]).ollamaUnloadMinutes == -1)
    }

    @Test func theRequestCarriesKeepAlive() throws {
        let temp = TempFolder()
        let pdf = temp.url.appendingPathComponent("scan.pdf")
        try TestPDF.make(pdf, pages: ["Fictional"])
        let analyzer = OllamaFacetAnalyzer(baseURL: URL(string: "http://localhost:11434")!, model: "m", sendImages: false,
                                           maxImagePages: 1, taxonomy: TestData.taxonomy, profile: .empty, unloadMinutes: 15)
        #expect(try analyzer.requestBody(ocrText: "x", pageCount: 1, pdf: pdf)["keep_alive"] == .string("15m"))
    }

    @Test func readsWhatIsLoadedAndWhenItUnloads() throws {
        let ps = try JSONValue(parsing: """
            {"models": [
              {"name": "qwen3-vl:8b-instruct", "size": 7000000000, "size_vram": 6500000000, "expires_at": "2030-03-01T09:15:00.123456789-07:00"},
              {"name": "kept:latest", "size": 1000, "expires_at": "2318-08-13T11:00:00-07:00"}
            ]}
            """)
        let loaded = OllamaClient.loadedModels(fromPS: ps)
        #expect(loaded.map(\.name) == ["qwen3-vl:8b-instruct", "kept:latest"])
        #expect(loaded[0].bytes == 6_500_000_000)
        let expected = try #require(FlexibleISO8601().date(from: "2030-03-01T16:15:00.123Z"))
        #expect(abs((loaded[0].unloadsAt ?? .distantPast).timeIntervalSince(expected)) < 0.001)
        #expect(loaded[1].unloadsAt == nil)   // kept loaded: no unload time to show
    }
}
