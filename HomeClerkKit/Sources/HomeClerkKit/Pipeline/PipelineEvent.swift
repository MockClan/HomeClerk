import Foundation

/// What the pipeline reports as it works, for the app to show. `source` is the scan's path in
/// the inbox, so a document can be followed from detection to its outcome. `engine` names the
/// model that analyzed it, nil when none did (e.g. an identical file).
public enum PipelineEvent: Sendable, Equatable {
    case problem(String)
    case ready(inbox: URL, organized: URL, review: URL)
    /// A PDF appeared in the inbox.
    case detected(source: URL)
    case stage(source: URL, stage: Stage, engine: String?)
    /// A detected document disappeared from the inbox before it was processed.
    case skipped(source: URL)
    case filed(path: URL, folder: String, source: URL, engine: String?, fallback: Bool)
    case review(path: URL, reason: String, source: URL, engine: String?, fallback: Bool)
    case duplicate(path: URL, original: String, source: URL, engine: String?, fallback: Bool)
    /// Processing of a scan is over, whatever its outcome — sent even when nothing else was (say,
    /// another program moved the file away mid-way), so nothing is left showing as in progress.
    case finished(source: URL)
    /// Ollama's state changed while it's the provider or fallback.
    case ollama(OllamaStatus)

    public enum Stage: String, Sendable {
        /// The scanner is still writing the file.
        case waiting
        case reading
        /// Sent again with the fallback engine if the primary fails.
        case analyzing
        case filing
    }
}

public struct OllamaStatus: Sendable, Equatable {
    public enum State: String, Sendable { case ready, stopped, missingModel = "missing-model" }
    public enum Role: String, Sendable { case primary, fallback }

    public var state: State
    public var model: String
    public var role: Role
}

public typealias PipelineEventHandler = @Sendable (PipelineEvent) -> Void
