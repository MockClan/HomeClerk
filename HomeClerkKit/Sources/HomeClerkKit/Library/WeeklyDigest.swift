import Foundation

/// Monday's summary notification: bills overdue or due, documents expiring, and work waiting in
/// Review — or nothing, in a quiet week.
public struct WeeklyDigest: Equatable, Sendable {
    public var title: String
    public var body: String
    /// Nothing is due, so a click should go where the waiting work is: Review.
    public var opensReview: Bool

    /// `items` is the week's Upcoming list (paid bills already left out); `today` is yyyy-MM-dd.
    public static func compose(items: [UpcomingItem], today: String, waitingScans: Int, waitingSince: Date?,
                               namesToConfirm: Int) -> WeeklyDigest? {
        guard !items.isEmpty || waitingScans > 0 || namesToConfirm > 0 else { return nil }
        let overdue = items.filter { $0.kind == .due && $0.date < today }
        let due = items.filter { $0.kind == .due && $0.date >= today }
        let expiring = items.filter { $0.kind == .expires }

        var parts: [String] = []
        if !overdue.isEmpty { parts.append(count(overdue.count, "bill overdue", "bills overdue")) }
        if !due.isEmpty { parts.append(count(due.count, "bill due", "bills due")) }
        if !expiring.isEmpty { parts.append(count(expiring.count, "document expiring", "documents expiring")) }
        if waitingScans > 0 { parts.append(count(waitingScans, "scan waiting in Review", "scans waiting in Review")) }

        // Overdue bills by name first: they're the ones that cost money
        var lines = overdue.prefix(3).map { "Overdue: \($0.title)" }
        lines += (due + expiring).sorted { $0.date < $1.date }.prefix(max(0, 3 - lines.count)).map(\.title)
        if waitingScans > 0 {
            lines.append("Review has had \(waitingScans == 1 ? "a scan" : "scans") waiting"
                         + (waitingSince.map { " since \($0.formatted(.dateTime.weekday(.wide).month().day()))" } ?? ""))
        }
        if namesToConfirm > 0 { lines.append(count(namesToConfirm, "name to confirm in Review", "names to confirm in Review")) }

        return WeeklyDigest(title: "This week: " + (parts.isEmpty ? "names to confirm" : parts.joined(separator: ", ")),
                            body: lines.joined(separator: "\n"), opensReview: items.isEmpty)
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
}
