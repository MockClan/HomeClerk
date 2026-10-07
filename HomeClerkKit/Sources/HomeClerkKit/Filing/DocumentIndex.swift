import CryptoKit
import Foundation

/// Append-only record of every filed document and the facets it was filed by (index.jsonl in
/// the HomeClerk folder, one JSON object per line), in the format HomeClerk has always used. Lets
/// documents be re-filed after taxonomy.json changes, tagged, or searched by due date without
/// re-running the AI.
public final class DocumentIndex: @unchecked Sendable {
    public static let fileName = "index.jsonl"

    public struct Entry: Codable, Equatable, Sendable {
        /// Persistent identity; unlike the path or facets, it survives corrections and renames.
        public var documentID: String
        /// Identifies the filing operation that committed this version, for crash recovery.
        public var operationID: String?
        public var filedAt: Date
        public var path: String
        public var source: String
        public var pages: [Int]
        public var model: String
        public var confidence: Double
        public var summary: String
        public var facets: DocumentFacets
        /// Its details were corrected after filing (Filed ▸ Edit Details).
        public var corrected = false
        /// A restoration of an unindexed file removes its newly added Library record.
        public var removed = false

        public init(documentID: String = UUID().uuidString, filedAt: Date = Date(), path: String, source: String, pages: [Int], model: String,
                    confidence: Double, summary: String, facets: DocumentFacets) {
            self.documentID = documentID
            self.filedAt = filedAt
            self.path = path
            self.source = source
            self.pages = pages
            self.model = model
            self.confidence = confidence
            self.summary = summary
            self.facets = facets
        }

        enum CodingKeys: String, CodingKey {
            case documentID = "document_id"
            case operationID = "operation_id"
            case filedAt = "filed_at", path, source, pages, model, confidence, summary, facets, corrected, removed
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let text = try c.decode(String.self, forKey: .filedAt)
            guard let date = FlexibleISO8601().date(from: text) else {
                throw DecodingError.dataCorruptedError(forKey: .filedAt, in: c, debugDescription: "bad date \(text)")
            }
            filedAt = date
            path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
            // Old index entries need the same identity on every read. Their first correction
            // persists this ID, so it follows the document to its new path afterwards.
            let storedID = try c.decodeIfPresent(String.self, forKey: .documentID)
            let legacyPath = URL(fileURLWithPath: path).standardizedFileURL.path
            documentID = storedID.flatMap { $0.isEmpty ? nil : $0 }
                ?? "legacy-" + SHA256.hash(data: Data(legacyPath.utf8)).map { String(format: "%02x", $0) }.joined()
            operationID = try c.decodeIfPresent(String.self, forKey: .operationID)
            source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
            pages = try c.decodeIfPresent([Int].self, forKey: .pages) ?? []
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
            confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
            summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
            facets = try c.decodeIfPresent(DocumentFacets.self, forKey: .facets) ?? DocumentFacets()
            corrected = try c.decodeIfPresent(Bool.self, forKey: .corrected) ?? false
            removed = try c.decodeIfPresent(Bool.self, forKey: .removed) ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(documentID, forKey: .documentID)
            try c.encodeIfPresent(operationID, forKey: .operationID)
            try c.encode(FlexibleISO8601().string(from: filedAt), forKey: .filedAt)
            try c.encode(path, forKey: .path)
            try c.encode(source, forKey: .source)
            try c.encode(pages, forKey: .pages)
            try c.encode(model, forKey: .model)
            try c.encode(confidence, forKey: .confidence)
            try c.encode(summary, forKey: .summary)
            try c.encode(facets, forKey: .facets)
            if removed { try c.encode(true, forKey: .removed) }
            if corrected { try c.encode(true, forKey: .corrected) }   // absent otherwise, as before
        }
    }

    public let url: URL
    /// Shared by every DocumentIndex for the same file: appending reads and rewrites the whole
    /// file, so two objects for one index (the old and new pipeline across a restart) must not
    /// interleave, or one's entries would be lost.
    private let lock: NSLock

    public init(url: URL) {
        self.url = url
        lock = Self.lock(for: url)
    }

    private static let locksLock = NSLock()
    nonisolated(unsafe) private static var locks: [String: NSLock] = [:]   // only touched under locksLock

    private static func lock(for url: URL) -> NSLock {
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path
        return locksLock.withLock {
            if let lock = locks[key] { return lock }
            let lock = NSLock()
            locks[key] = lock
            return lock
        }
    }

    public func append(_ entry: Entry) throws {
        try append([entry])
    }

    /// Commits all entries together. A failed write must leave the existing index intact.
    public func append(_ entries: [Entry]) throws {
        guard !entries.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let lines = try entries.reduce(into: Data()) { data, entry in
            data.append(try encoder.encode(stored(entry)))
            data.append(Data("\n".utf8))
        }
        try lock.withLock {
            var data = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Data()
            // Isolate a partial line left by an older append-based version.
            if !data.isEmpty, data.last != 0x0A { data.append(0x0A) }
            data.append(lines)
            try PrivateFile.write(data, to: url)
        }
    }

    /// Every entry, skipping lines that can't be read.
    public func load() -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { (try? decoder.decode(Entry.self, from: Data($0.utf8))).map(resolved) }
    }

    /// Repair decisions must not interpret unreadable or malformed history as an empty archive.
    public func loadValidated() throws -> [Entry] {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let text = try String(contentsOf: url, encoding: .utf8)
            let decoder = JSONDecoder()
            return try text.split(separator: "\n").map { resolved(try decoder.decode(Entry.self, from: Data($0.utf8))) }
        }
    }

    // MARK: Paths relative to the folder

    /// The folder the index lives in (the HomeClerk folder). Paths inside it are stored relative to
    /// it, so the folder can be moved — renamed, put on another drive, or into iCloud Drive.
    var base: String { url.deletingLastPathComponent().path }

    /// The folders a document's path always runs through. A full path from before paths were
    /// relative — or from where the folder used to be — is rebased onto the folder at the first one.
    static let managedFolders: Set<String> = ["Organized", "_review", "_duplicates", "_originals", "Inbox"]

    /// The entry as written: relative to the folder when it's inside it.
    func stored(_ entry: Entry) -> Entry {
        guard let relative = relativePath(entry.path) else { return entry }
        var entry = entry
        entry.path = relative
        return entry
    }

    /// The entry as read: a full path inside the folder as it is now.
    func resolved(_ entry: Entry) -> Entry {
        var entry = entry
        if !entry.path.hasPrefix("/") {
            entry.path = base + "/" + entry.path
        } else if let relative = relativePath(entry.path) {
            entry.path = base + "/" + relative   // in the folder's own spelling (/var or /private/var)
        } else {
            let parts = entry.path.split(separator: "/")
            if let start = parts.firstIndex(where: { Self.managedFolders.contains(String($0)) }) {
                entry.path = base + "/" + parts[start...].joined(separator: "/")
            }
        }
        return entry
    }

    /// `path` relative to the folder, or nil when it's outside it.
    private func relativePath(_ path: String) -> String? {
        let folder = url.deletingLastPathComponent()
        for prefix in [folder.standardizedFileURL.path, folder.resolvingSymlinksInPath().path] where path.hasPrefix(prefix + "/") {
            return String(path.dropFirst(prefix.count + 1))
        }
        return nil
    }
}
