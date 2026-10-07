import Foundation

/// When Ollama is the AI provider or the fallback, checks that it's running with the configured
/// model pulled and reports changes, so the app can say so before a scan fails. Checks every
/// few seconds while Ollama isn't ready (so starting it is noticed quickly), then once a minute.
public actor OllamaMonitor {
    let baseURL: URL
    let model: String
    let role: OllamaStatus.Role
    let events: PipelineEventHandler
    let session: URLSession
    private var task: Task<Void, Never>?

    public init(baseURL: URL, model: String, role: OllamaStatus.Role, events: @escaping PipelineEventHandler,
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.role = role
        self.events = events
        self.session = session
    }

    /// "primary" or "fallback" when Ollama is in use; nil when it isn't.
    public static func role(for settings: HomeClerkSettings) -> OllamaStatus.Role? {
        guard settings.readerPolicyProblem(for: .ollama) == nil else { return nil }
        if settings.aiProvider == .ollama { return .primary }
        if settings.fallbackProvider == .ollama { return .fallback }
        return nil
    }

    public func start() {
        task = Task {
            var last: OllamaStatus.State?
            while !Task.isCancelled {
                let state = await check()
                if state != last {
                    events(.ollama(OllamaStatus(state: state, model: model, role: role)))
                    last = state
                }
                try? await Task.sleep(for: state == .ready ? .seconds(60) : .seconds(5))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    func check() async -> OllamaStatus.State {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"), timeoutInterval: 5)
        request.httpMethod = "GET"
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONValue(parsing: String(decoding: data, as: UTF8.self)) else { return .stopped }
        let names = (json["models"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        return Self.hasModel(names, model) ? .ready : .missingModel
    }

    /// Ollama lists models with a tag; a configured name without one means ":latest".
    public static func hasModel(_ pulled: [String], _ configured: String) -> Bool {
        let wanted = configured.contains(":") ? configured : configured + ":latest"
        return pulled.contains { TextRules.equalsIgnoringCase($0, wanted) }
    }
}
