import Foundation
import os

/// Detects documents HomeClerk has already filed, persisted across restarts in
/// `_duplicates/.simhash-index.json`.
///
/// Two checks:
/// - Exact — the same file bytes (a PDF dropped into the inbox twice). Free: runs before any AI call.
/// - Near — a rescan of the same paper. The Simhash of the OCR text must be within the Hamming
///   threshold *and* the key facets (vendor, date, person, amount, vehicle, pet) must match. Text
///   similarity alone isn't enough: the same form letter sent to several family members, or a
///   monthly statement, differs only in a name or date and scores as near-identical.
public final class DuplicateDetector: @unchecked Sendable {
    public static let indexFileName = ".simhash-index.json"

    /// OCR text shorter than this has too little signal for a stable Simhash.
    public static let minTextLength = 150

    fileprivate struct Entry: Codable, Sendable {
        var fingerprint: UInt64 = 0
        var label = ""
        var sha256: String?
        /// Key facets; nil for split segments and for entries written before facet matching.
        var key: String?

        enum CodingKeys: String, CodingKey { case fingerprint, label, sha256, key }

        init(fingerprint: UInt64, label: String, sha256: String?, key: String?) {
            self.fingerprint = fingerprint
            self.label = label
            self.sha256 = sha256
            self.key = key
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fingerprint = try c.decodeIfPresent(UInt64.self, forKey: .fingerprint) ?? 0
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
            key = try c.decodeIfPresent(String.self, forKey: .key)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(fingerprint, forKey: .fingerprint)
            try c.encode(label, forKey: .label)
            try c.encode(sha256, forKey: .sha256)
            try c.encode(key, forKey: .key)
        }
    }

    struct Snapshot: Codable, Sendable {
        fileprivate var entries: [Entry]
        func containsOnly(label: String) -> Bool { entries.allSatisfy { $0.label == label } }
    }

    func snapshot(label: String) -> Snapshot {
        lock.withLock { Snapshot(entries: index.filter { $0.label == label }) }
    }

    /// Persist before changing the in-memory view, so failure can be reported and retried.
    func restore(_ snapshot: Snapshot, replacing labels: Set<String>) throws {
        try lock.withLock {
            let restored = index.filter { !labels.contains($0.label) } + snapshot.entries
            try PrivateFile.writeJSON(restored, to: indexURL)
            index = restored
        }
    }

    func replace(ocrText: String, sha256: String, facets: DocumentFacets, label: String,
                 replacing labels: Set<String>) throws {
        try restore(Snapshot(entries: [Self.entry(ocrText: ocrText, sha256: sha256, facets: facets, label: label)]), replacing: labels)
    }

    private let indexURL: URL
    private let hammingThreshold: Int
    private let lock = NSLock()
    private var index: [Entry] = []
    private let log = Logger(subsystem: "com.mockclan.homeclerk", category: "duplicates")

    /// Loads the index from `duplicatesFolder`, creating the folder if needed.
    public init(duplicatesFolder: URL, hammingThreshold: Int = 3) {
        self.hammingThreshold = hammingThreshold
        indexURL = duplicatesFolder.appendingPathComponent(Self.indexFileName)
        try? FileManager.default.createDirectory(at: duplicatesFolder, withIntermediateDirectories: true)
        load()
    }

    /// The label of an earlier document with exactly these bytes, if there is one.
    public func exactDuplicate(sha256: String) -> String? {
        lock.withLock { index.first { $0.sha256 == sha256 }?.label }
    }

    /// The label of an earlier document with near-identical text and the same key facets, if any.
    public func nearDuplicate(ocrText: String, facets: DocumentFacets) -> String? {
        guard ocrText.utf16.count >= Self.minTextLength else { return nil }
        let fingerprint = Simhash.compute(ocrText)
        let key = Self.facetKey(facets)
        return lock.withLock {
            index.first {
                $0.key == key && Simhash.hammingDistance(fingerprint, $0.fingerprint) <= hammingThreshold
            }?.label
        }
    }

    /// Records a filed document. Pass nil `facets` for a split segment, which then only matches
    /// as an exact duplicate of the whole scan.
    public func register(ocrText: String, sha256: String, facets: DocumentFacets?, label: String) {
        let entry = Self.entry(ocrText: ocrText, sha256: sha256, facets: facets, label: label)
        lock.withLock {
            index.append(entry)
            save()
        }
    }

    /// Forgets a filed document, e.g. when its filing is undone.
    public func unregister(label: String) {
        lock.withLock {
            index.removeAll { $0.label == label }
            save()
        }
    }

    /// Read-only inspection; unlike initialization it never creates folders or hides decode errors.
    public static func recordedLabels(in folder: URL) throws -> [String] {
        let url = folder.appendingPathComponent(indexFileName)
        try FileOrganizer.requireInside(url, folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url)).map(\.label)
    }

    public func removeStaleLabel(_ label: String, organized: URL) throws {
        try lock.withLock {
            let target = organized.appendingPathComponent(label)
            try FileOrganizer.requireInside(target, organized)
            guard !FileManager.default.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists) }
            try FileOrganizer.requireInside(indexURL, indexURL.deletingLastPathComponent())
            let saved = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: indexURL))
            guard saved.contains(where: { $0.label == label }) else { throw CocoaError(.fileReadNoSuchFile) }
            let remaining = saved.filter { $0.label != label }
            try PrivateFile.writeJSON(remaining, to: indexURL)
            index = remaining
        }
    }

    /// Replaces the whole index, e.g. when rebuilding it from the document index.
    public func rebuild(_ documents: [(ocrText: String, sha256: String, facets: DocumentFacets, label: String)]) {
        let entries = documents.map { Self.entry(ocrText: $0.ocrText, sha256: $0.sha256, facets: $0.facets, label: $0.label) }
        lock.withLock {
            index = entries
            save()
        }
    }

    /// Facets that differ between genuinely different documents from the same sender.
    public static func facetKey(_ f: DocumentFacets) -> String {
        let amount = f.amount.map(TextRules.amount) ?? ""
        return [TextRules.key(f.vendor), f.documentDate, TextRules.key(f.person), amount,
                TextRules.key(f.vehicle), TextRules.key(f.pet)].joined(separator: "|")
    }

    private static func entry(ocrText: String, sha256: String, facets: DocumentFacets?, label: String) -> Entry {
        let key = facets.flatMap { ocrText.utf16.count < minTextLength ? nil : facetKey($0) }
        return Entry(fingerprint: Simhash.compute(ocrText), label: label, sha256: sha256, key: key)
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        do {
            index = try JSONDecoder().decode([Entry].self, from: data)
            let legacy = index.filter { $0.key == nil && $0.sha256 == nil }.count
            if legacy > 0 { log.info("Ignoring \(legacy) duplicate-index entries from before facet matching") }
        } catch {
            log.warning("Could not load the duplicate index — starting fresh: \(error.localizedDescription)")
        }
    }

    /// Called with the lock held.
    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(index).write(to: indexURL, options: .atomic)
        } catch {
            log.warning("Could not save the duplicate index: \(error.localizedDescription)")
        }
    }
}
