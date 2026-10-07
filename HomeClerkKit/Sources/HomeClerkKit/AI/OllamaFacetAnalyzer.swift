import Foundation
import os

/// Extracts document facets with a local Ollama vision model (e.g. qwen3-vl:8b-instruct). Sends
/// page images plus OCR text; Ollama's structured outputs constrain the reply to the same schema
/// Claude uses. The configured server determines where processing happens.
public struct OllamaFacetAnalyzer: FacetAnalyzer {
    public let model: String
    public let baseURL: URL
    let sendImages: Bool
    let maxImagePages: Int
    let profile: HouseholdProfile
    let systemPrompt: String
    let schema: JSONValue
    let session: URLSession
    private let log = Logger(subsystem: "com.mockclan.homeclerk", category: "ollama")

    public init(baseURL: URL, model: String, sendImages: Bool, maxImagePages: Int, taxonomy: TaxonomyConfig,
                profile: HouseholdProfile, session: URLSession = .shared, unloadMinutes: Int = 5) {
        self.unloadMinutes = unloadMinutes
        self.baseURL = baseURL
        self.model = model
        self.sendImages = sendImages
        self.maxImagePages = maxImagePages
        self.profile = profile
        self.session = session
        systemPrompt = FacetPrompt.buildSystem(taxonomy, profile)
        // Small local models pick far more reliably from an enum of tags
        schema = FacetSchema.build(taxonomy, constrainTags: true)
    }

    /// Minutes Ollama keeps the model loaded after this request; -1 keeps it loaded.
    let unloadMinutes: Int

    /// Ollama's keep_alive: "5m" to unload after five idle minutes, -1 to keep the model loaded.
    static func keepAlive(minutes: Int) -> JSONValue {
        minutes < 0 ? .number(-1) : .string("\(minutes)m")
    }

    public var modelName: String { "Ollama \(model)" }
    public var isPaid: Bool { false }

    func requestBody(ocrText: String, pageCount: Int, pdf: URL) throws -> JSONValue {
        let images = sendImages
            ? try PageRenderer.pngs(of: pdf, dpi: PageRenderer.modelDPI, limit: maxImagePages)
                .map { JSONValue.string($0.base64EncodedString()) }
            : []
        return .object([
            ("model", .string(model)),
            ("stream", .bool(false)),
            ("format", schema),
            ("keep_alive", Self.keepAlive(minutes: unloadMinutes)),
            ("options", .object([
                ("temperature", .number(0)),
                // System prompt (~5K tokens) + OCR + images; 16K leaves room for long statements
                ("num_ctx", .number(16384))
            ])),
            ("messages", .array([
                .object([("role", .string("system")), ("content", .string(systemPrompt))]),
                .object([
                    ("role", .string("user")),
                    ("content", .string(FacetPrompt.buildUserText(ocrText: ocrText, pageCount: pageCount))),
                    ("images", .array(images))
                ])
            ]))
        ])
    }

    public func analyze(ocrText: String, pageCount: Int, pdf: URL) async -> FacetAnalysis {
        // Local vision models can take a minute or more on a multi-page scan
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"), timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        do {
            request.httpBody = Data(try requestBody(ocrText: ocrText, pageCount: pageCount, pdf: pdf).serialized.utf8)
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: data, as: UTF8.self)
            guard status == 200 else {
                log.error("Ollama returned \(status)")
                return .failed("Ollama HTTP \(status): \(body.prefix(500))", transient: status >= 500)
            }
            let json = (try? JSONValue(parsing: body))?["message"]?["content"]?.stringValue ?? ""
            return FacetSchema.parse(json, pageCount: pageCount, modelName: modelName, profile: profile)
        } catch let error as URLError where error.code == .timedOut {
            return .failed("Ollama request timed out", transient: true)
        } catch let error as URLError where error.code == .cancelled {
            return .failed("Cancelled")
        } catch let error as URLError {
            log.error("Cannot reach Ollama: \(error.localizedDescription, privacy: .private)")
            return .failed("Ollama not reachable — is 'ollama serve' running?", transient: true)
        } catch {
            return .failed("Ollama analysis failed: \(error)")
        }
    }
}
