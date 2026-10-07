import Foundation

/// Paid API use by month and model, from usage.jsonl.
public struct UsageSummary: Sendable {
    public struct Row: Identifiable, Sendable, Equatable {
        /// yyyy-MM
        public var month: String
        public var model: String
        public var calls: Int
        /// Input tokens including cache writes and reads.
        public var inputTokens: Int
        public var outputTokens: Int
        /// nil when no call in the row had a known price.
        public var cost: Decimal?
        public var id: String { "\(month) \(model)" }
        /// Estimated cost per call — each scan is read in one call, so this is the cost per scan
        /// (a retried scan counts twice). nil without a known price.
        public var averageCost: Decimal? { cost.flatMap { calls > 0 ? $0 / Decimal(calls) : nil } }
    }

    public let rows: [Row]
    public var total: Decimal { rows.compactMap(\.cost).reduce(0, +) }
    /// Average cost per call across every call with a known price.
    public var averageCost: Decimal? {
        let priced = rows.filter { $0.cost != nil }
        let calls = priced.reduce(0) { $0 + $1.calls }
        return calls > 0 ? total / Decimal(calls) : nil
    }

    /// "1.8¢" under a dollar, "$1.25" otherwise — per-scan costs are mostly fractions of a cent.
    public static func perScan(_ amount: Decimal) -> String {
        let value = NSDecimalNumber(decimal: amount).doubleValue
        guard value < 1 else { return amount.formatted(.currency(code: "USD")) }
        let cents = value * 100
        return (cents < 10 ? cents.formatted(.number.precision(.fractionLength(1))) : cents.formatted(.number.precision(.fractionLength(0)))) + "¢"
    }

    public init(_ entries: [UsageLedger.Entry], calendar: Calendar = .current) {
        var groups: [String: Row] = [:]
        for e in entries {
            let c = calendar.dateComponents([.year, .month], from: e.at)
            let month = String(format: "%04d-%02d", c.year!, c.month!)
            var row = groups["\(month) \(e.model)"] ?? Row(month: month, model: e.model, calls: 0, inputTokens: 0,
                                                            outputTokens: 0, cost: nil)
            row.calls += 1
            row.inputTokens += e.input + e.cacheWrite + e.cacheRead
            row.outputTokens += e.output
            if let cost = e.cost { row.cost = (row.cost ?? 0) + cost }
            groups[row.id] = row
        }
        rows = groups.values.sorted { ($0.month, $0.model) < ($1.month, $1.model) }
    }
}
