import Foundation

/// The same paper filed twice — two scans of it, or a scan of its first page and later one of
/// all of it — found among filed documents, for Tidy Up.
public struct FiledDuplicate: Equatable, Sendable, Identifiable {
    /// By document, so a rename doesn't forget that you kept both.
    public var id: String { [keep.documentID, extra.documentID].sorted().joined(separator: "\n") }
    /// The fuller copy.
    public var keep: DocumentIndex.Entry
    /// The copy that can go.
    public var extra: DocumentIndex.Entry
    /// The extra copy holds only some of the pages.
    public var partial: Bool
}

public enum FiledDuplicates {
    /// Pairs of filed documents from different scans that are the same paper: near-identical text
    /// with the same details (the test a new scan gets, description aside), or nearly all (85%) of
    /// one's words in the other with the same sender, date, person, and amount — a scan of its
    /// first page, say. Two readings of one paper often describe it differently, so this looks
    /// further than a new scan's check; you confirm each one. Copies within one scan are never
    /// compared — several copies of a form in one pile are deliberate. Pairs you chose to keep
    /// (by `id`) aren't listed again.
    public static func find(_ documents: [DocumentIndex.Entry], texts: [String: String], hammingThreshold: Int = 3,
                            keepingBoth: Set<String> = []) -> [FiledDuplicate] {
        struct Reading {
            var entry: DocumentIndex.Entry
            var words: [String: Int]
            var total: Int
            var fingerprint: UInt64
            var key: String?
            var about: String
        }
        let readings = documents.map { entry in
            let text = texts[entry.path] ?? ""
            var words: [String: Int] = [:]
            for match in text.lowercased().matches(of: /[a-z0-9]{3,}/) { words[String(match.output), default: 0] += 1 }
            return Reading(entry: entry, words: words, total: words.values.reduce(0, +), fingerprint: Simhash.compute(text),
                           key: text.utf16.count < DuplicateDetector.minTextLength ? nil : DuplicateDetector.facetKey(entry.facets),
                           about: TextRules.key(entry.facets.description))
        }
        func rescan(_ a: Reading, _ b: Reading) -> Bool {
            guard let x = a.key, let y = b.key else { return false }
            return DuplicateDetector.sameFacets(x, y) && Simhash.hammingDistance(a.fingerprint, b.fingerprint) <= hammingThreshold
        }
        func sameDetails(_ a: Reading, _ b: Reading) -> Bool {
            let x = a.entry.facets, y = b.entry.facets
            return a.total >= 40 && b.total >= 40
                && !x.vendor.isEmpty && TextRules.key(x.vendor) == TextRules.key(y.vendor)
                && !x.documentDate.isEmpty && x.documentDate == y.documentDate
                && DuplicateDetector.sameOrUnknown(TextRules.key(x.person), TextRules.key(y.person))
                && (x.amount == nil || y.amount == nil || x.amount == y.amount)
        }
        /// The share of each one's words found in the other.
        func overlap(_ a: Reading, _ b: Reading) -> (Double, Double) {
            let shared = Double(a.words.reduce(0) { $0 + min($1.value, b.words[$1.key] ?? 0) })
            return (shared / Double(max(a.total, 1)), shared / Double(max(b.total, 1)))
        }
        // The copy to keep: more of the document, then the one that names who it's about, then the
        // one without a "_2" HomeClerk added for a name already taken, then the first filed
        func fuller(_ a: Reading, _ b: Reading) -> Bool {
            if a.total != b.total { return a.total > b.total }
            if a.entry.facets.person.isEmpty != b.entry.facets.person.isEmpty { return !a.entry.facets.person.isEmpty }
            let suffixed = { (r: Reading) in URL(fileURLWithPath: r.entry.path).deletingPathExtension().lastPathComponent.contains(/_\d+$/) }
            if suffixed(a) != suffixed(b) { return !suffixed(a) }
            return a.entry.filedAt < b.entry.filedAt
        }
        var found: [FiledDuplicate] = [], extras = Set<String>()
        for (i, a) in readings.enumerated() {
            for b in readings[(i + 1)...] where a.entry.source != b.entry.source {
                guard rescan(a, b) || sameDetails(a, b) else { continue }
                let (inB, inA) = overlap(a, b)
                guard rescan(a, b) || max(inA, inB) >= 0.85 else { continue }
                // Mostly the same words both ways is one document; otherwise the extra holds some of its pages
                let partial = !rescan(a, b) && min(inA, inB) < 0.8
                let (keep, extra) = fuller(a, b) ? (a, b) : (b, a)
                let pair = FiledDuplicate(keep: keep.entry, extra: extra.entry, partial: partial)
                guard !extras.contains(extra.entry.path), !keepingBoth.contains(pair.id) else { continue }
                extras.insert(extra.entry.path)
                found.append(pair)
            }
        }
        return found
    }
}
