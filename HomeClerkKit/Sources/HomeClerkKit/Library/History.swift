import Foundation

/// What happened to each scan — filed, sent to Review, set aside as a duplicate, or a problem —
/// kept in history.jsonl in the HomeClerk folder, so Activity outlasts a restart. One JSON object
/// per line; readable only by this account, since it names your documents.
public final class HistoryLog: @unchecked Sendable {
    public static let fileName = "history.jsonl"

    public struct Entry: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case filed, review, duplicate, added, problem }
        public var at: Date
        public var kind: Kind
        public var title: String
        public var detail: String
        public var path: String?
        public var engine: String?
        public var fallback: Bool

        public init(at: Date = Date(), kind: Kind, title: String, detail: String, path: String? = nil,
                    engine: String? = nil, fallback: Bool = false) {
            self.at = at
            self.kind = kind
            self.title = title
            self.detail = detail
            self.path = path
            self.engine = engine
            self.fallback = fallback
        }
    }

    public let url: URL
    private let lock = NSLock()

    public init(folder: URL) { url = folder.appendingPathComponent(Self.fileName) }

    public func append(_ entry: Entry) {
        guard let line = try? Self.encoder.encode(entry) else { return }
        lock.withLock {
            // A missing history line must never fail a document
            try? PrivateFile.append(line + Data("\n".utf8), to: url)
        }
    }

    /// The newest `limit` entries, newest first; lines that can't be read are skipped.
    public func recent(_ limit: Int = 300) -> [Entry] {
        let text = lock.withLock { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        return text.split(separator: "\n").suffix(limit).reversed()
            .compactMap { try? Self.decoder.decode(Entry.self, from: Data($0.utf8)) }
    }

    /// Keeps the file from growing without end: past `keep` lines, only the newest `keep` stay.
    public func trim(keep: Int = 5000) {
        lock.withLock {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let lines = text.split(separator: "\n")
            guard lines.count > keep else { return }
            try? PrivateFile.write(Data((lines.suffix(keep).joined(separator: "\n") + "\n").utf8), to: url)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .sortedKeys
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
