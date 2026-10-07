import Foundation
import PDFKit

/// The words printed in filed documents — their text layers — for finding a document by anything
/// on the page, not only the details HomeClerk read. Each document's text is cached (in the private
/// HomeClerk folder) and read again only when the file changes.
public final class FullTextIndex: @unchecked Sendable {
    public static let fileName = "fulltext.json"

    private struct Cached: Codable {
        var modified: Double
        var size: Int
        var text: String
    }

    /// A document whose text has every search word, with the text around the first.
    public struct Match: Sendable, Equatable {
        public var entry: DocumentIndex.Entry
        public var snippet: String
    }

    let url: URL
    private var cache: [String: Cached]
    private var changed = false
    private let lock = NSLock()

    /// `folder` is where the cache lives — `.homeclerk-cache` in the HomeClerk folder.
    public init(folder: URL) {
        url = folder.appendingPathComponent(Self.fileName)
        cache = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Cached].self, from: $0) } ?? [:]
    }

    /// Documents whose text contains every word of `query` (case and accents ignored).
    public func search(_ query: String, in documents: [DocumentIndex.Entry]) -> [Match] {
        let words = query.split(separator: " ").map { Self.fold(String($0)) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let matches: [Match] = documents.compactMap { entry in
            let text = text(of: entry)
            let folded = Self.fold(text)
            guard words.allSatisfy(folded.contains) else { return nil }
            return Match(entry: entry, snippet: Self.snippet(text, folded: folded, around: words[0]))
        }
        save()
        return matches
    }

    /// A document's text, from the cache while the file is unchanged.
    func text(of entry: DocumentIndex.Entry) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: entry.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        if let hit = lock.withLock({ cache[entry.path] }), hit.modified == modified, hit.size == size { return hit.text }
        let text = PDFDocument(url: URL(fileURLWithPath: entry.path))?.string ?? ""
        lock.withLock {
            cache[entry.path] = Cached(modified: modified, size: size, text: text)
            changed = true
        }
        return text
    }

    /// Writes the cache if anything was added, dropping documents that no longer exist. Readable
    /// only by this account: it holds what's printed in your documents.
    func save() {
        lock.withLock {
            guard changed else { return }
            cache = cache.filter { FileManager.default.fileExists(atPath: $0.key) }
            changed = false
            guard let data = try? JSONEncoder().encode(cache) else { return }
            try? PrivateFile.write(data, to: url)
        }
    }

    /// Lowercased, without accents, with line breaks and runs of spaces made single spaces — so
    /// "Électricité\nDue" matches "electricite due". Keeps every character's position, mostly;
    /// snippets are cut from the original text by a proportional position, which is close enough.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// About eighty characters around the first search word, on one line.
    static func snippet(_ text: String, folded: String, around word: String) -> String {
        guard let range = folded.range(of: word) else { return "" }
        let offset = folded.distance(from: folded.startIndex, to: range.lowerBound)
        let original = Array(text.replacingOccurrences(of: "\n", with: " "))
        let start = max(0, min(offset, original.count) - 40), end = min(original.count, offset + word.count + 40)
        guard start < end else { return "" }
        let piece = String(original[start..<end]).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (start > 0 ? "…" : "") + piece + (end < original.count ? "…" : "")
    }
}
