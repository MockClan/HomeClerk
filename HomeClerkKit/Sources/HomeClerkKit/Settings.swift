import Foundation

/// HomeClerk's settings: the choices that matter to how documents are filed. They live in the app's
/// preferences (`SettingsStore`), edited in HomeClerk ▸ Settings. Everything else is fixed below.
/// What reads documents. The raw value is the stored setting and the name shown.
public enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    /// Most accurate; paid, with an API key.
    case claude = "Claude"
    /// Local and free.
    case ollama = "Ollama"
    /// On-device and free, with Apple Intelligence.
    case apple = "Apple"

    public var id: String { rawValue }

    /// "ollama" → .ollama; nil for anything that isn't a provider.
    public init?(named name: String) {
        guard let provider = Self.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) else { return nil }
        self = provider
    }
}

public struct HomeClerkSettings: Sendable, Equatable {

    /// The HomeClerk folder; Inbox, Organized, _review, _duplicates, and _originals are inside it.
    public var basePath: URL
    /// Keep a copy of each scan, as it arrived, in _originals.
    public var preserveOriginals = true
    /// Restrict document analysis to Apple on-device or a loopback Ollama endpoint.
    public var localReadersOnly = false

    public var aiProvider = AIProvider.claude
    /// Used when `aiProvider` fails (out of credit, refusal, outage); nil for none.
    public var fallbackProvider: AIProvider? = .ollama
    public var claudeModel = "claude-sonnet-5-5"
    public var ollamaModel = "qwen3-vl:8b-instruct"
    /// How long Ollama keeps the model in memory after a document, so it isn't held for hours
    /// while HomeClerk sits in the background. Each document restarts the clock; -1 keeps it loaded.
    public var ollamaUnloadMinutes = 5
    public var ollamaBaseURL = URL(string: "http://localhost:11434")!
    /// "on-device" or "private-cloud".
    public var appleModel = "on-device"

    /// How sure the model must be to file a document; below it the scan goes to review.
    public var minConfidenceThreshold = 0.70
    /// The bar for a fallback model's result — higher, because local models are less accurate.
    public var fallbackMinConfidence = 0.85
    /// Dollars Claude may spend in a calendar month before HomeClerk stops using it (the fallback, if
    /// any, takes over). 0 means no limit.
    public var claudeMonthlyLimit = 0.0

    /// Add an invisible OCR text layer so scans are searchable in Preview and Spotlight.
    public var makeSearchable = true
    /// Tag filed documents in Finder (area, person, vehicle, pet, facet tags).
    public var applyFinderTags = true
    /// Create Reminders for bill due dates and upcoming expirations.
    public var createReminders = false
    public var remindersList = "HomeClerk"
    /// How many days before an expiration its reminder comes due.
    public var expirationReminderLeadDays = 30

    // MARK: Fixed

    /// Seconds a new scan sits before processing, in case more files are arriving.
    public let debounceSeconds = 3
    /// Bits two text fingerprints may differ by and still count as a rescan.
    public let duplicateHammingThreshold = 3
    public let claudeEffort = "medium"
    public let sendPageImages = true
    /// Page images sent to a local model (Claude receives the whole PDF).
    public let maxImagePages = 2

    // MARK: Folders

    public var inboxFolder: URL { basePath.appendingPathComponent("Inbox") }
    public var outboxFolder: URL { basePath.appendingPathComponent("Organized") }
    public var reviewFolder: URL { basePath.appendingPathComponent("_review") }
    public var originalsFolder: URL { basePath.appendingPathComponent("_originals") }
    public var duplicatesFolder: URL { basePath.appendingPathComponent("_duplicates") }
    public var householdProfilePath: URL { basePath.appendingPathComponent(HouseholdProfile.fileName) }

    /// UI disclosure for a configured reader, including the fallback.
    /// Never include URL credentials, path, query, or fragment in the displayed destination.
    public func analysisDestination(for provider: AIProvider) -> String {
        if let reason = readerPolicyProblem(for: provider) { return "Blocked. " + reason }
        switch provider {
        case .claude:
            return "Claude sends document text and the PDF to Anthropic's cloud API."
        case .apple:
            return appleModel == "private-cloud"
                ? "Apple Private Cloud Compute is selected; document analysis may leave this Mac."
                : "Apple's on-device model reads documents on this Mac."
        case .ollama:
            guard let components = URLComponents(url: ollamaBaseURL, resolvingAgainstBaseURL: false),
                  let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = components.host, !host.isEmpty else {
                return "Ollama has an invalid server address. Check Settings ▸ Ollama."
            }
            let port = components.port.map { ":\($0)" } ?? ""
            let destination = "\(scheme)://\(host)\(port)"
            return ollamaUsesLoopback
                ? "Ollama receives document text and page images at \(destination) on this Mac. Server-side cloud models or forwarding can still send them elsewhere."
                : "Ollama sends document text and page images to the remote server at \(destination)."
        }
    }

    public var ollamaUsesLoopback: Bool {
        guard let host = ollamaBaseURL.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    public var ollamaTransportWarning: String? {
        guard ollamaBaseURL.scheme?.lowercased() == "http", !ollamaUsesLoopback else { return nil }
        return "This remote Ollama connection uses HTTP. Document text and page images travel without transport encryption. Use HTTPS or a server on this Mac."
    }

    public var analysisPrivacySummary: String {
        let primary = "Primary: " + analysisDestination(for: aiProvider)
        guard let fallback = fallbackProvider, fallback != aiProvider else {
            return primary + "\nIf reading fails, the scan goes to Review."
        }
        if let reason = readerPolicyProblem(for: fallback) {
            return primary + "\nFallback blocked: " + reason + " If the primary fails, the scan goes to Review."
        }
        return primary + "\nFallback: " + analysisDestination(for: fallback)
            + " The fallback can be used automatically when the primary fails, including after a refusal or spending-limit check."
    }

    public func readerPolicyProblem(for provider: AIProvider) -> String? {
        guard localReadersOnly else { return nil }
        let reason: String?
        switch provider {
        case .claude: reason = "Claude uses a cloud API"
        case .apple: reason = appleModel == "on-device" ? nil : "Apple is not configured for on-device analysis"
        case .ollama:
            if !["http", "https"].contains(ollamaBaseURL.scheme?.lowercased() ?? "") || !ollamaUsesLoopback {
                reason = "Ollama is not configured for a loopback HTTP/HTTPS endpoint"
            } else if ollamaModel.lowercased().contains("cloud") {
                reason = "the Ollama model name indicates cloud processing"
            } else { reason = nil }
        }
        return reason.map { "Local readers only: \($0). Choose a permitted reader in Settings ▸ Analysis." }
    }

    /// Avoid DNS resolution for localhost when the policy is enabled.
    public var analysisOllamaURL: URL {
        guard localReadersOnly, ollamaBaseURL.host?.lowercased() == "localhost",
              var components = URLComponents(url: ollamaBaseURL, resolvingAgainstBaseURL: false) else { return ollamaBaseURL }
        components.host = "127.0.0.1"
        return components.url ?? ollamaBaseURL
    }

    public static let defaultBasePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("HomeClerk")

    /// A HomeClerk folder moved elsewhere (another drive, iCloud Drive) with a link left in its
    /// place is the user's choice, so the link itself is followed once, here. Everything else then
    /// sees the real folder, and links inside it are still refused. Ancestors aren't touched.
    static func followingFolderLink(_ folder: URL) -> URL {
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) else { return folder }
        return folder.resolvingSymlinksInPath()
    }

    public init(basePath: URL = HomeClerkSettings.defaultBasePath) { self.basePath = basePath }

    /// Settings from stored values keyed by name (case-insensitive); anything missing or unusable
    /// keeps its default.
    init(values: [String: JSONValue]) {
        let values = Dictionary(values.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
        func text(_ key: String) -> String? {
            switch values[key.lowercased()] {
            case let .string(s)?: s
            case let .number(n)?: n == n.rounded() ? Int(checking: n).map(String.init) ?? String(n) : String(n)
            case let .bool(b)?: String(b)
            default: nil
            }
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool { text(key).map { $0.lowercased() == "true" } ?? fallback }
        func number(_ key: String, _ fallback: Double) -> Double {
            text(key).flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } ?? fallback
        }
        func integer(_ key: String, _ fallback: Int) -> Int { text(key).flatMap(Double.init).flatMap(Int.init(checking:)) ?? fallback }

        self.init()
        if let path = text("BasePath"), !path.trimmingCharacters(in: .whitespaces).isEmpty {
            basePath = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        basePath = Self.followingFolderLink(basePath)
        preserveOriginals = flag("PreserveOriginals", preserveOriginals)
        localReadersOnly = flag("LocalReadersOnly", localReadersOnly)
        if let provider = text("AiProvider").flatMap(AIProvider.init(named:)) { aiProvider = provider }
        if let fallback = text("FallbackProvider") { fallbackProvider = AIProvider(named: fallback) }
        claudeModel = text("ClaudeModel").flatMap { $0.isEmpty ? nil : $0 } ?? claudeModel
        ollamaModel = text("OllamaModel").flatMap { $0.isEmpty ? nil : $0 } ?? ollamaModel
        ollamaUnloadMinutes = min(max(integer("OllamaUnloadMinutes", ollamaUnloadMinutes), -1), 1440)
        ollamaBaseURL = text("OllamaBaseUrl").flatMap(URL.init(string:)).flatMap { $0.scheme == nil ? nil : $0 } ?? ollamaBaseURL
        appleModel = text("AppleModel") == "private-cloud" ? "private-cloud" : "on-device"
        minConfidenceThreshold = min(max(number("MinConfidenceThreshold", minConfidenceThreshold), 0), 1)
        fallbackMinConfidence = min(max(number("FallbackMinConfidence", fallbackMinConfidence), 0), 1)
        claudeMonthlyLimit = min(max(number("ClaudeMonthlyLimit", claudeMonthlyLimit), 0), 10_000)
        makeSearchable = flag("MakeSearchable", makeSearchable)
        applyFinderTags = flag("ApplyFinderTags", applyFinderTags)
        createReminders = flag("CreateReminders", createReminders)
        remindersList = text("RemindersList").flatMap { $0.isEmpty ? nil : $0 } ?? remindersList
        expirationReminderLeadDays = min(max(integer("ExpirationReminderLeadDays", expirationReminderLeadDays), 0), 365)
    }

    /// Each setting's stored name and value, as `SettingsStore` saves it.
    var storedValues: [(key: String, value: Any)] {
        [("BasePath", basePath.path), ("PreserveOriginals", preserveOriginals), ("LocalReadersOnly", localReadersOnly), ("AiProvider", aiProvider.rawValue),
         ("FallbackProvider", fallbackProvider?.rawValue ?? ""), ("ClaudeModel", claudeModel), ("OllamaModel", ollamaModel),
         ("OllamaUnloadMinutes", ollamaUnloadMinutes),
         ("OllamaBaseUrl", ollamaBaseURL.absoluteString), ("AppleModel", appleModel),
         ("MinConfidenceThreshold", minConfidenceThreshold), ("FallbackMinConfidence", fallbackMinConfidence),
         ("ClaudeMonthlyLimit", claudeMonthlyLimit),
         ("MakeSearchable", makeSearchable), ("ApplyFinderTags", applyFinderTags), ("CreateReminders", createReminders),
         ("RemindersList", remindersList), ("ExpirationReminderLeadDays", expirationReminderLeadDays)]
    }

    /// Safe diagnostic summaries. User-entered strings are never exported verbatim.
    /// Keep this allowlist separate from storedValues so new settings default to exclusion.
    public var diagnosticValues: [(key: String, value: String)] {
        let defaults = Self()
        func model(_ value: String, _ builtIn: String) -> String {
            value == builtIn ? builtIn : "custom (value omitted)"
        }
        return [
            ("BasePath", basePath == Self.defaultBasePath ? "default folder" : "custom folder (path omitted)"),
            ("PreserveOriginals", String(preserveOriginals)),
            ("LocalReadersOnly", String(localReadersOnly)),
            ("AiProvider", aiProvider.rawValue),
            ("FallbackProvider", fallbackProvider?.rawValue ?? "none"),
            ("ClaudeModel", model(claudeModel, defaults.claudeModel)),
            ("OllamaModel", model(ollamaModel, defaults.ollamaModel)),
            ("OllamaBaseUrl", DiagnosticPrivacy.endpoint(ollamaBaseURL)),
            ("AppleModel", model(appleModel, defaults.appleModel)),
            ("MinConfidenceThreshold", String(minConfidenceThreshold)),
            ("FallbackMinConfidence", String(fallbackMinConfidence)),
            ("ClaudeMonthlyLimit", String(claudeMonthlyLimit)),
            ("MakeSearchable", String(makeSearchable)),
            ("ApplyFinderTags", String(applyFinderTags)),
            ("CreateReminders", String(createReminders)),
            ("RemindersList", remindersList == defaults.remindersList ? "default list" : "custom list (name omitted)"),
            ("ExpirationReminderLeadDays", String(expirationReminderLeadDays))
        ]
    }

    public static func == (a: HomeClerkSettings, b: HomeClerkSettings) -> Bool {
        a.storedValues.map { "\($0.key)=\($0.value)" } == b.storedValues.map { "\($0.key)=\($0.value)" }
    }
}

/// Where the settings are kept: the app's preferences (the com.mockclan.homeclerk defaults domain),
/// which the command-line tool reads too. HOMECLERK_HomeClerk__<Name> environment variables override
/// them, for testing against a scratch folder.
public struct SettingsStore: @unchecked Sendable {
    public static let domain = "com.mockclan.homeclerk"

    let defaults: UserDefaults

    /// The app's own preferences; from another process, the same domain by name.
    public static var app: SettingsStore {
        SettingsStore(defaults: Bundle.main.bundleIdentifier == domain ? .standard : UserDefaults(suiteName: domain)!)
    }

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> HomeClerkSettings {
        var values: [String: JSONValue] = [:]
        for (key, _) in HomeClerkSettings().storedValues {
            switch defaults.object(forKey: key) {
            case let s as String: values[key] = .string(s)
            case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): values[key] = .bool(n.boolValue)
            case let n as NSNumber: values[key] = .number(n.doubleValue)
            default: break
            }
        }
        let prefix = "homeclerk_homeclerk__"
        for (key, value) in environment where key.lowercased().hasPrefix(prefix) {
            values[String(key.dropFirst(prefix.count))] = .string(value)
        }
        return HomeClerkSettings(values: values)
    }

    /// Stores settings that differ from the defaults and clears the rest, so a future change to a
    /// default still reaches anyone who never changed that setting.
    public func save(_ settings: HomeClerkSettings) {
        let builtIn = Dictionary(HomeClerkSettings().storedValues.map { ($0.key, "\($0.value)") }, uniquingKeysWith: { $1 })
        for (key, value) in settings.storedValues {
            if builtIn[key] == "\(value)" { defaults.removeObject(forKey: key) } else { defaults.set(value, forKey: key) }
        }
    }
}
