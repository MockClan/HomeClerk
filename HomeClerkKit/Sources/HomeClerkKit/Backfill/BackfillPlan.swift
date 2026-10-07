import Foundation

/// What backfill proposes for one already-filed document. The same JSON plans have always used,
/// so a plan made by either can be applied by either.
public struct BackfillEntry: Sendable, Equatable {
    public enum Action: String, Sendable, Comparable {
        case keep, rename, move, skip
        public static func < (a: Action, b: Action) -> Bool { a.order < b.order }
        var order: Int { [.keep: 0, .rename: 1, .move: 2, .skip: 3][self]! }
        var title: String { rawValue.capitalized }
    }

    /// Path relative to the Organized folder at planning time.
    public var path: String
    public var sha256: String
    public var action: Action = .skip
    /// Whether apply acts on this entry. Edit to false to leave a file alone.
    public var apply = false
    public var reason = ""
    public var proposedFolder = ""
    public var proposedName = ""
    public var handCorrected = false
    public var confidence = 0.0
    public var model = ""
    public var summary = ""
    public var facets: DocumentFacets?

    init(json: JSONValue) {
        path = json["path"]?.stringValue ?? ""
        sha256 = json["sha256"]?.stringValue ?? ""
        action = json["action"]?.stringValue.flatMap { Action(rawValue: $0.lowercased()) } ?? .skip
        apply = json["apply"] == .bool(true)
        reason = json["reason"]?.stringValue ?? ""
        proposedFolder = json["proposed_folder"]?.stringValue ?? ""
        proposedName = json["proposed_name"]?.stringValue ?? ""
        handCorrected = json["hand_corrected"] == .bool(true)
        confidence = json["confidence"]?.doubleValue ?? 0
        model = json["model"]?.stringValue ?? ""
        summary = json["summary"]?.stringValue ?? ""
        facets = json["facets"].flatMap { $0 == .null ? nil : try? JSONDecoder().decode(DocumentFacets.self, from: Data($0.serialized.utf8)) }
    }

    init(path: String, sha256: String, handCorrected: Bool) {
        self.path = path
        self.sha256 = sha256
        self.handCorrected = handCorrected
    }

    var json: JSONValue {
        .object([
            ("path", .string(path)), ("sha256", .string(sha256)), ("action", .string(action.rawValue)),
            ("apply", .bool(apply)), ("reason", .string(reason)), ("proposed_folder", .string(proposedFolder)),
            ("proposed_name", .string(proposedName)), ("hand_corrected", .bool(handCorrected)),
            ("confidence", .number(confidence)), ("model", .string(model)), ("summary", .string(summary)),
            ("facets", facets.map { (try? JSONValue(parsing: String(decoding: JSONEncoder().encode($0), as: UTF8.self))) ?? .null } ?? .null)
        ])
    }
}

public struct BackfillPlan: Sendable {
    public var createdAt: Date
    public var organizedFolder: String
    public var model: String
    public var entries: [BackfillEntry]

    public static func load(from url: URL) throws -> BackfillPlan {
        let json = try JSONValue(parsing: String(contentsOf: url, encoding: .utf8))
        return BackfillPlan(createdAt: json["created_at"]?.stringValue.flatMap { FlexibleISO8601().date(from: $0) } ?? Date(),
                            organizedFolder: json["organized_folder"]?.stringValue ?? "",
                            model: json["model"]?.stringValue ?? "",
                            entries: (json["entries"]?.arrayValue ?? []).map(BackfillEntry.init(json:)))
    }

    public func save(to url: URL) throws {
        let json: JSONValue = .object([
            ("created_at", .string(createdAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon)))),
            ("organized_folder", .string(organizedFolder)),
            ("model", .string(model)),
            ("entries", .array(entries.map(\.json)))
        ])
        try json.pretty().appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// A readable summary of the plan, grouped by what would happen.
    public func markdown() -> String {
        var out = ""
        func line(_ s: String = "") { out += s + "\n" }
        let stamp = createdAt.formatted(Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: .current, calendar: .current))
        line("# HomeClerk backfill plan — \(stamp)")
        line()
        line("\(entries.count) documents in `\(organizedFolder)`, analyzed with \(model).")
        line()
        for action in Set(entries.map(\.action)).sorted() {
            let group = entries.filter { $0.action == action }
            line("- **\(action.title)**: \(group.count) (\(group.filter(\.apply).count) will be applied)")
        }
        line()
        line("Every applied entry also gets a searchable text layer, Finder tags, and an index entry")
        line("(and reminders, if CreateReminders is on). To leave a file alone, set its \"apply\" to false")
        line("in the JSON plan before applying it.")

        func section(_ title: String, _ list: [BackfillEntry]) {
            guard !list.isEmpty else { return }
            line("\n## \(title) (\(list.count))\n")
            line("| Apply | Now | Proposed | Why |")
            line("|---|---|---|---|")
            for e in list {
                let proposed = e.action == .skip ? "—" : "\(e.proposedFolder)/\(e.proposedName)"
                line("| \(e.apply ? "yes" : "no") | \(cell(e.path)) | \(cell(proposed)) | \(cell(e.reason)) |")
            }
        }
        section("Move to a different folder", entries.filter { $0.action == .move && !$0.handCorrected })
        section("Rename in place", entries.filter { $0.action == .rename && !$0.handCorrected })
        section("Filed by hand — the model disagrees (not applied unless you opt in)",
                entries.filter { $0.handCorrected && ($0.action == .move || $0.action == .rename) })
        section("Skipped", entries.filter { $0.action == .skip })
        return out
    }

    private func cell(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
