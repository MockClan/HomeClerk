/// 64-bit Simhash fingerprints of text. Near-duplicate documents (e.g. accidental rescans) produce
/// fingerprints with a low Hamming distance — few bits different.
public enum Simhash {
    // At least 3 characters, to filter out articles, conjunctions, and OCR noise
    nonisolated(unsafe) private static let token = /[a-z0-9]{3,}/

    /// The fingerprint of `text`; 0 for empty or whitespace-only text.
    public static func compute(_ text: String) -> UInt64 {
        guard text.contains(where: { !$0.isWhitespace }) else { return 0 }

        var vector = [Int](repeating: 0, count: 64)
        for match in text.lowercased().matches(of: token) {
            let hash = fnv1a64(match.output)
            for bit in 0..<64 {
                vector[bit] += hash & (1 << UInt64(bit)) != 0 ? 1 : -1
            }
        }

        var fingerprint: UInt64 = 0
        for bit in 0..<64 where vector[bit] > 0 { fingerprint |= 1 << UInt64(bit) }
        return fingerprint
    }

    /// Bits that differ: 0 is identical; 1–3 suggests a rescan under typical scanning conditions.
    public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    // FNV-1a 64-bit — deterministic across runs. Tokens are ASCII, so bytes and UTF-16 units agree.
    private static func fnv1a64(_ s: Substring) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for unit in s.utf16 {
            hash ^= UInt64(unit)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }
}
