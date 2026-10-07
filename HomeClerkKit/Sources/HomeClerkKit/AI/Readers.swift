import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What can read documents on this Mac — a Claude key, Apple Intelligence, Ollama — for choosing
/// sensible providers on a first run, and for saying so when nothing configured can.
public struct Readers: Sendable, Equatable {
    public var hasClaudeKey: Bool
    public var appleIntelligence: Bool
    public var ollamaInstalled: Bool

    public init(hasClaudeKey: Bool, appleIntelligence: Bool, ollamaInstalled: Bool) {
        self.hasClaudeKey = hasClaudeKey
        self.appleIntelligence = appleIntelligence
        self.ollamaInstalled = ollamaInstalled
    }

    /// This Mac, now.
    public static func detect() -> Readers {
        Readers(hasClaudeKey: Keychain.readAPIKey() != nil, appleIntelligence: appleIntelligenceAvailable,
                ollamaInstalled: ollamaInstalledHere)
    }

    /// Apple's on-device model is ready to use (macOS 27 with Apple Intelligence turned on).
    public static var appleIntelligenceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 27, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    static var ollamaInstalledHere: Bool {
        ["/Applications/Ollama.app", "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Providers for a first run: Claude when there's a key (it's the most accurate), otherwise the
    /// free readers this Mac has — with whatever else is available as the fallback.
    public var firstRunChoice: (provider: AIProvider, fallback: AIProvider?) {
        let order: [AIProvider] = [.claude, .apple, .ollama]
        let usable = order.filter { canRead(with: $0) }
        guard let first = usable.first else { return (.claude, nil) }   // the assistant asks for a key
        return (first, usable.dropFirst().first)
    }

    func canRead(with provider: AIProvider?) -> Bool {
        switch provider {
        case .claude?: hasClaudeKey
        case .apple?: appleIntelligence
        case .ollama?: ollamaInstalled
        case nil: false
        }
    }

    /// Why no scan can be read with these settings, or nil when the provider or fallback can.
    /// (Ollama installed but stopped is the Ollama banner's to explain.)
    public func problem(_ settings: HomeClerkSettings) -> String? {
        func permitted(_ provider: AIProvider?) -> Bool {
            guard let provider else { return false }
            return settings.readerPolicyProblem(for: provider) == nil && canRead(with: provider)
        }
        if permitted(settings.aiProvider) || permitted(settings.fallbackProvider) { return nil }
        if let policy = settings.readerPolicyProblem(for: settings.aiProvider) {
            return policy + " No permitted fallback is available."
        }
        let reason: String
        switch settings.aiProvider {
        case .claude: reason = "Claude needs an Anthropic API key"
        case .apple: reason = "Apple Intelligence isn't available on this Mac (it needs macOS 27 and Apple Intelligence turned on)"
        case .ollama: reason = "Ollama isn't installed"
        }
        return reason + (settings.fallbackProvider == nil ? ", and there's no fallback." : ", and the fallback can't run either.")
    }
}
