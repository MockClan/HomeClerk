import Foundation

/// Append-only record of paid API calls (usage.jsonl in the HomeClerk folder), so spending is
/// never a surprise. One JSON object per line.
public final class UsageLedger: @unchecked Sendable {
    public static let fileName = "usage.jsonl"

    public struct Entry: Codable, Equatable, Sendable {
        public var at: Date
        public var model: String
        public var input: Int
        public var output: Int
        public var cacheWrite: Int
        public var cacheRead: Int
        /// Estimated USD; nil when the model's price isn't known.
        public var cost: Decimal?

        enum CodingKeys: String, CodingKey {
            case at, model, input, output, cacheWrite = "cache_write", cacheRead = "cache_read", cost
        }
    }

    /// USD per million tokens: input, output, cache write, cache read.
    private static let prices: [(model: String, input: Decimal, output: Decimal, cacheWrite: Decimal, cacheRead: Decimal)] = [
        ("claude-sonnet-5-5", 2, 10, 2.5, 0.2),
        ("claude-opus-5-5", 4, 20, 5, 0.2),
        ("claude-sonnet-4-6", 3, 15, 3.75, 0.3),
        ("claude-haiku-4-5", 1, 5, 1.25, 0.1)
    ]

    public static func estimateCost(model: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> Decimal? {
        // Responses may name a dated snapshot; match on the base model id
        guard let p = prices.first(where: { model.hasPrefix($0.model) }) else { return nil }
        let tokens = Decimal(input) * p.input + Decimal(output) * p.output
            + Decimal(cacheWrite) * p.cacheWrite + Decimal(cacheRead) * p.cacheRead
        return tokens / 1_000_000
    }

    private let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    /// Estimated dollars spent in the calendar month containing `date`.
    public func spent(inMonthOf date: Date = Date(), calendar: Calendar = .current) -> Decimal {
        let entries = lock.withLock { (try? Self.load(from: url)) ?? [] }
        return entries.filter { calendar.isDate($0.at, equalTo: date, toGranularity: .month) }
            .compactMap(\.cost).reduce(0, +)
    }

    public func record(model: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) {
        let entry = Entry(at: Date(), model: model, input: input, output: output, cacheWrite: cacheWrite,
                          cacheRead: cacheRead,
                          cost: Self.estimateCost(model: model, input: input, output: output,
                                                  cacheWrite: cacheWrite, cacheRead: cacheRead))
        guard let line = try? Self.encoder.encode(entry) else { return }
        lock.withLock {
            // A missing ledger line must never fail a document
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line + Data("\n".utf8))
                try? handle.close()
            } else {
                try? (line + Data("\n".utf8)).write(to: url)
            }
        }
    }

    public static func load(from url: URL) throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { !$0.isEmpty }
            .map { try decoder.decode(Entry.self, from: Data($0.utf8)) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)
                .timeZone(separator: .colon)))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            // Older entries (from the original .NET version) have up to seven fractional digits and a local offset
            if let date = FlexibleISO8601().date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
        }
        return decoder
    }()
}

/// ISO 8601 parsing that also accepts seven-digit fractional seconds, as older entries have.
struct FlexibleISO8601: Sendable {
    /// Match the millisecond precision of the legacy decoder without ISO8601FormatStyle's
    /// truncation of floating-point values just below the next millisecond.
    // Made once: formatters are slow to create, and every index entry and usage line is parsed
    // with them. ISO8601DateFormatter is documented as thread-safe.
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func string(from date: Date) -> String { Self.withFraction.string(from: date) }

    func date(from text: String) -> Date? {
        if let date = Self.withFraction.date(from: text) ?? Self.plain.date(from: text) { return date }
        // More than three fractional digits (as .NET wrote them): trim to three, which it understands
        let trimmed = text.replacing(/\.(\d{3})\d+/) { ".\($0.1)" }
        return Self.withFraction.date(from: trimmed) ?? Self.plain.date(from: trimmed)
    }
}
