import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Extracts document facets with Apple's Foundation Models — the on-device model, or Private
/// Cloud Compute. Free to run. The on-device model has a small context window (8K tokens on
/// macOS 27), so when a document doesn't fit this steps down: drop page images, then trim the
/// OCR text.
public struct AppleFacetAnalyzer: FacetAnalyzer {
    /// "on-device" or "private-cloud".
    public let model: String
    let sendImages: Bool
    let maxImagePages: Int
    let profile: HouseholdProfile
    let instructions: String
    let documentTypes: [String]
    let areas: [String]
    let tags: [String]
    private let log = Logger(subsystem: "com.mockclan.homeclerk", category: "apple")

    public init(model: String, sendImages: Bool, maxImagePages: Int, taxonomy: TaxonomyConfig, profile: HouseholdProfile) {
        self.model = model
        self.sendImages = sendImages
        self.maxImagePages = maxImagePages
        self.profile = profile
        instructions = FacetPrompt.buildSystem(taxonomy, profile)
        documentTypes = taxonomy.documentTypes.map(\.name)
        areas = taxonomy.areas.map(\.name)
        tags = taxonomy.suggestedTags.map(\.tag)
    }

    public var modelName: String { model == "private-cloud" ? "Apple Private Cloud Compute" : "Apple on-device" }
    public var isPaid: Bool { false }

    public func analyze(ocrText: String, pageCount: Int, pdf: URL) async -> FacetAnalysis {
        #if canImport(FoundationModels)
        if #available(macOS 27, *) {
            // The on-device model runs one request at a time; queueing keeps each attempt's time honest
            return await AppleModelGate.shared.run {
                await analyzeOnMacOS27(ocrText: ocrText, pageCount: pageCount, pdf: pdf)
            }
        }
        #endif
        return .failed("\(modelName): Foundation Models needs macOS 27")
    }

    #if canImport(FoundationModels)
    @available(macOS 27, *)
    private func analyzeOnMacOS27(ocrText: String, pageCount: Int, pdf: URL) async -> FacetAnalysis {
        let images: [URL]
        do {
            images = sendImages ? try writeImages(of: pdf) : []
        } catch {
            return .failed("\(modelName): \(error)")
        }
        defer { for url in images { try? FileManager.default.removeItem(at: url) } }

        // Step down until the request fits: full → no images → OCR trimmed to 60% → 35%
        var attempts: [(images: [URL], ocrShare: Double, label: String)] = [
            (images, 1, images.isEmpty ? "full OCR" : "\(images.count) image(s) + full OCR"),
            ([], 1, "full OCR, no images"),
            ([], 0.6, "60% of OCR"),
            ([], 0.35, "35% of OCR")
        ]
        if images.isEmpty { attempts.remove(at: 1) }

        var lastError = "no response"
        for attempt in attempts {
            let text = attempt.ocrShare < 1
                ? String(String.UnicodeScalarView(ocrText.unicodeScalars.prefix(Int(Double(ocrText.unicodeScalars.count) * attempt.ocrShare))))
                    + "\n[OCR text truncated]"
                : ocrText
            switch await generate(prompt: FacetPrompt.buildUserText(ocrText: text, pageCount: pageCount), images: attempt.images) {
            case let .success(json):
                var analysis = FacetSchema.parse(json, pageCount: pageCount, modelName: modelName, profile: profile)
                analysis.summary = "[\(attempt.label)] \(analysis.summary)"
                return analysis
            case let .failure(failure):
                lastError = failure.message
                guard failure.kind == .contextSizeExceeded else {
                    return .failed("\(modelName): \(failure.message)", transient: failure.kind == .transient)
                }
                log.debug("Apple context exceeded with \(attempt.label, privacy: .public) — stepping down")
            }
        }
        return .failed("\(modelName): document doesn't fit the context window (\(lastError))")
    }

    struct GenerationFailure: Error {
        enum Kind { case unavailable, contextSizeExceeded, guardrail, transient, failed }
        let kind: Kind
        let message: String
    }

    @available(macOS 27, *)
    private func generate(prompt text: String, images: [URL]) async -> Result<String, GenerationFailure> {
        let schema: GenerationSchema
        do {
            schema = try facetSchema()
        } catch {
            return .failure(.init(kind: .failed, message: "schema: \(error)"))
        }
        let prompt = Prompt {
            for url in images { Attachment(imageURL: url) }
            text
        }

        let session: LanguageModelSession
        if model == "private-cloud" {
            let cloud = PrivateCloudComputeLanguageModel()
            guard cloud.isAvailable else {
                return .failure(.init(kind: .unavailable, message: "Private Cloud Compute unavailable: \(cloud.availability)"))
            }
            session = LanguageModelSession(model: cloud, instructions: instructions)
        } else {
            let onDevice = SystemLanguageModel.default
            guard onDevice.isAvailable else {
                return .failure(.init(kind: .unavailable, message: "Apple Intelligence unavailable: \(onDevice.availability)"))
            }
            session = LanguageModelSession(model: onDevice, instructions: instructions)
        }

        do {
            // Greedy sampling: classification should be repeatable, not creative
            let response = try await session.respond(to: prompt, schema: schema,
                                                     options: GenerationOptions(samplingMode: .greedy))
            return .success(Self.nullZeroAmounts(response.content.jsonString))
        } catch let error as LanguageModelError {
            let kind: GenerationFailure.Kind = switch error {
            case .contextSizeExceeded: .contextSizeExceeded
            case .guardrailViolation, .refusal: .guardrail
            case .rateLimited, .timeout: .transient
            default: .failed
            }
            return .failure(.init(kind: kind, message: "\(error)"))
        } catch {
            return .failure(.init(kind: .failed, message: "\(error)"))
        }
    }

    /// Mirrors FacetSchema: summary first, then one entry per document. Tags come from the
    /// suggested list, with a required primary tag, as for other local models.
    @available(macOS 27, *)
    private func facetSchema() throws -> GenerationSchema {
        func text(_ name: String) -> DynamicGenerationSchema.Property {
            .init(name: name, schema: DynamicGenerationSchema(type: String.self))
        }
        // Required free text made the on-device model fill person, vehicle, and pet on every
        // document — with household names from the prompt. A choice of "none" or one of the
        // household's own names keeps it honest (it can't name someone new; Claude and Ollama can).
        func choice(_ name: String, _ label: String, _ names: [String]) -> DynamicGenerationSchema.Property {
            .init(name: name, description: "Who or what in the household this document is about, or none",
                  schema: DynamicGenerationSchema(name: label, anyOf: [Self.none] + names))
        }
        let document = DynamicGenerationSchema(name: "Document", properties: [
            .init(name: "first_page", schema: DynamicGenerationSchema(type: Int.self)),
            .init(name: "last_page", schema: DynamicGenerationSchema(type: Int.self)),
            .init(name: "document_type", schema: DynamicGenerationSchema(name: "DocumentType", anyOf: documentTypes)),
            .init(name: "area", schema: DynamicGenerationSchema(name: "Area", anyOf: areas)),
            // A required single choice forces a tag decision; optional lists tend to stay empty
            .init(name: "primary_tag", description: "The single suggested tag that best describes this document, or none",
                  schema: DynamicGenerationSchema(name: "PrimaryTag", anyOf: tags + ["none"])),
            .init(name: "tags", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(name: "Tag", anyOf: tags))),
            text("vendor"), text("description"), text("document_date"), text("due_date"), text("expires_on"),
            // Required with 0 meaning "none": the on-device model skips optional fields entirely
            .init(name: "amount", description: "Total amount; 0 when the document has none",
                  schema: DynamicGenerationSchema(type: Double.self)),
            choice("person", "Person", Self.unique((profile.people + profile.groups).map(\.name))),
            choice("vehicle", "Vehicle", Self.unique(profile.vehicles.map(\.name))),
            choice("pet", "Pet", Self.unique(profile.pets.map(\.name))),
            .init(name: "confidence", schema: DynamicGenerationSchema(type: Double.self))
        ])
        let root = DynamicGenerationSchema(name: "Facets", properties: [
            text("summary"),
            .init(name: "documents", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(referenceTo: "Document")))
        ])
        return try GenerationSchema(root: root, dependencies: [document])
    }
    #endif

    private func writeImages(of pdf: URL) throws -> [URL] {
        try PageRenderer.pngs(of: pdf, dpi: PageRenderer.modelDPI, limit: maxImagePages).map { png in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("homeclerk_fm_\(UUID().uuidString).png")
            try png.write(to: url)
            return url
        }
    }

    /// The person/vehicle/pet choice meaning "not about anyone in particular".
    static let none = "none"

    static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && $0 != none && seen.insert($0).inserted }
    }

    /// Converts the schema's placeholders back: "amount: 0" to null, and a "none" person, vehicle,
    /// or pet to empty.
    static func nullZeroAmounts(_ json: String) -> String {
        guard var root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let documents = root["documents"] as? [[String: Any]] else { return json }
        root["documents"] = documents.map { document -> [String: Any] in
            var document = document
            if let amount = document["amount"] as? Double, amount == 0 { document["amount"] = NSNull() }
            for key in ["person", "vehicle", "pet"] where (document[key] as? String) == none { document[key] = "" }
            return document
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return json }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Runs one Foundation Models request at a time.
actor AppleModelGate {
    static let shared = AppleModelGate()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        }
        busy = true
        defer {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
        return await body()
    }
}
