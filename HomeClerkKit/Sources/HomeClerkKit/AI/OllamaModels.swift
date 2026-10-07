import Foundation

/// A model downloaded into Ollama, as Settings lists it.
public struct OllamaModelInfo: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var sizeBytes: Int64
    /// "8.8B"
    public var parameterSize: String
    /// Whether it can look at page images; nil when Ollama didn't say.
    public var readsImages: Bool?

    public init(name: String, sizeBytes: Int64, parameterSize: String = "", readsImages: Bool? = nil) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.parameterSize = parameterSize
        self.readsImages = readsImages
    }
}

/// Models worth suggesting, with how they generally compare. The ratings are general guidance;
/// what HomeClerk measures on your own documents (ModelTrackRecord) is shown alongside once there is any.
public struct RecommendedModel: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    /// Ollama's download size.
    public var sizeBytes: Int64
    /// 1 (basic) to 4 (best).
    public var accuracy: Int
    /// 1 (slowest) to 4 (fastest).
    public var speed: Int
    public var note: String
}

public enum OllamaCatalog {
    private static let gb: Int64 = 1_000_000_000

    /// Qwen3-VL instruct models, which read page images and answer in JSON without a thinking pass.
    /// Sizes are Ollama's (ollama.com/library/qwen3-vl/tags); check them when changing the list.
    public static let recommended: [RecommendedModel] = [
        RecommendedModel(name: "qwen3-vl:2b-instruct", sizeBytes: 1_900_000_000, accuracy: 1, speed: 4,
                         note: "Smallest. For Macs with 8 GB of memory; expect more scans in Review."),
        RecommendedModel(name: "qwen3-vl:4b-instruct", sizeBytes: 3_300_000_000, accuracy: 2, speed: 3,
                         note: "Quicker than the default; fine on 8 GB if little else is open."),
        RecommendedModel(name: "qwen3-vl:8b-instruct", sizeBytes: 6_100_000_000, accuracy: 3, speed: 2,
                         note: "HomeClerk's default. Needs 16 GB or more."),
        RecommendedModel(name: "qwen3-vl:30b-a3b-instruct", sizeBytes: 20 * gb, accuracy: 4, speed: 2,
                         note: "Most accurate. For 48 GB Macs and up; quicker than its size suggests.")
    ]

    public static let accuracyNames = ["", "Basic", "Good", "Better", "Best"]
    public static let speedNames = ["", "Slowest", "Moderate", "Fast", "Fastest"]

    /// Memory a model needs while it runs: its weights plus working room for a document and its images.
    public static func memoryNeeded(_ sizeBytes: Int64) -> Int64 { sizeBytes + 1_500_000_000 }

    public enum Fit: Sendable { case comfortable, tight, tooBig }

    /// Comfortable within half the Mac's memory (the rest is for macOS and your apps), tight up to
    /// three quarters, too big beyond.
    public static func fit(_ sizeBytes: Int64, memory: UInt64) -> Fit {
        let need = Double(memoryNeeded(sizeBytes)), total = Double(memory)
        return need <= total * 0.5 ? .comfortable : need <= total * 0.75 ? .tight : .tooBig
    }

    /// The most accurate recommended model that fits comfortably; the smallest when none does.
    public static func recommendation(memory: UInt64) -> RecommendedModel {
        recommended.last { fit($0.sizeBytes, memory: memory) == .comfortable } ?? recommended[0]
    }

    // MARK: Reading Ollama's replies

    /// /api/tags → the downloaded models (without `readsImages`, which /api/show answers).
    public static func models(fromTags json: JSONValue) -> [OllamaModelInfo] {
        (json["models"]?.arrayValue ?? []).compactMap { m in
            guard let name = m["name"]?.stringValue else { return nil }
            return OllamaModelInfo(name: name, sizeBytes: Int64(m["size"]?.doubleValue ?? 0),
                                   parameterSize: m["details"]?["parameter_size"]?.stringValue ?? "")
        }
    }

    /// /api/show → whether the model takes images. Newer Ollama lists capabilities; older ones
    /// show a vision projector or a CLIP family instead.
    public static func readsImages(fromShow json: JSONValue) -> Bool? {
        if let capabilities = json["capabilities"]?.stringArray { return capabilities.contains("vision") }
        if json["projector_info"] != nil { return true }
        if let families = json["details"]?["families"]?.stringArray { return families.contains { ["clip", "mllama"].contains($0) } }
        return nil
    }
}

/// Talks to Ollama for Settings: which models are downloaded, and downloading another.
public struct OllamaClient: Sendable {
    public let baseURL: URL
    let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// The downloaded models, with whether each reads images.
    public func models() async throws -> [OllamaModelInfo] {
        let tags = try await json("api/tags", body: nil)
        var models = OllamaCatalog.models(fromTags: tags)
        for i in models.indices {
            if let show = try? await json("api/show", body: .object([("model", .string(models[i].name))])) {
                models[i].readsImages = OllamaCatalog.readsImages(fromShow: show)
            }
        }
        return models.sorted { $0.name < $1.name }
    }

    /// Downloads a model, reporting progress (0–1, when Ollama knows the size) and its status line.
    public func pull(_ name: String, progress: @escaping @Sendable (Double?, String) -> Void) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"), timeoutInterval: 3600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(JSONValue.object([("model", .string(name)), ("stream", .bool(true))]).serialized.utf8)
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PullFailed(message: "Ollama refused the download") }
        // One JSON object per line
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let update = try? JSONValue(parsing: line) else { continue }
            if let error = update["error"]?.stringValue { throw PullFailed(message: error) }
            let status = update["status"]?.stringValue ?? ""
            let total = update["total"]?.doubleValue, completed = update["completed"]?.doubleValue
            progress(total.flatMap { t in t > 0 ? (completed ?? 0) / t : nil }, status)
            if status == "success" { return }
        }
    }

    public struct PullFailed: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// A model Ollama has in memory, and when it will unload on its own (nil: kept loaded).
    public struct LoadedModel: Equatable, Sendable {
        public var name: String
        public var unloadsAt: Date?
        public var bytes: Int64
    }

    /// The models in memory right now.
    public func loaded() async throws -> [LoadedModel] {
        Self.loadedModels(fromPS: try await json("api/ps", body: nil))
    }

    static func loadedModels(fromPS ps: JSONValue) -> [LoadedModel] {
        (ps["models"]?.arrayValue ?? []).compactMap { model in
            guard let name = model["name"]?.stringValue else { return nil }
            let expires = model["expires_at"]?.stringValue.flatMap { FlexibleISO8601().date(from: Self.trimmingNanoseconds($0)) }
            // Ollama reports a date centuries ahead (year 2318) for a model kept loaded
            let unloads = expires.flatMap { $0.timeIntervalSinceNow > 50 * 365 * 86_400 ? nil : $0 }
            return LoadedModel(name: name, unloadsAt: unloads,
                               bytes: Int64(model["size_vram"]?.doubleValue ?? model["size"]?.doubleValue ?? 0))
        }
    }

    /// "2026-10-07T09:15:00.123456789-06:00" → milliseconds, which date parsers understand.
    static func trimmingNanoseconds(_ text: String) -> String {
        text.replacing(/\.(\d{3})\d+/) { ".\($0.1)" }
    }

    /// Frees the model's memory now (Ollama's documented way: a request with keep_alive 0).
    public func unload(_ model: String) async throws {
        _ = try await json("api/generate", body: .object([("model", .string(model)), ("keep_alive", .number(0))]))
    }

    private func json(_ path: String, body: JSONValue?) async throws -> JSONValue {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 10)
        request.httpMethod = body == nil ? "GET" : "POST"
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.serialized.utf8)
        }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONValue(parsing: String(decoding: data, as: UTF8.self))
    }
}

/// How a model has done on your documents, from HomeClerk's own records: how many it filed
/// confidently, and how many needed you — Review, or a correction afterwards.
public struct ModelTrackRecord: Sendable, Equatable {
    public var analyzed = 0
    /// Filed straight away and never corrected.
    public var filedOnItsOwn = 0

    /// nil until there are enough documents for the number to mean something.
    public var share: Double? { analyzed >= 5 ? Double(filedOnItsOwn) / Double(analyzed) : nil }

    /// Index entries name models like "Ollama qwen3-vl:8b-instruct"; `model` is the Ollama name.
    public static func of(_ model: String, in documents: [DocumentIndex.Entry], pendingInReview: Int = 0) -> ModelTrackRecord {
        var record = ModelTrackRecord()
        for entry in documents where entry.model.lowercased().hasSuffix(model.lowercased()) {
            record.analyzed += 1
            if !entry.source.hasPrefix("review:") && !entry.corrected { record.filedOnItsOwn += 1 }
        }
        record.analyzed += pendingInReview
        return record
    }
}
