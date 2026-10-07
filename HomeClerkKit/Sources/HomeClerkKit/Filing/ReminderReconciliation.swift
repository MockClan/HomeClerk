import Foundation

/// Pure matching plan; EventKit applies it only after the entire plan validates.
enum ReminderReconciliation {
    struct Request: Sendable {
        var documentID: String?
        var items: [ReminderItem]
        var previous: [ReminderItem] = []
        /// Kinds whose date has passed: their reminder is kept as it is, not removed — an expired
        /// registration that hasn't been renewed still needs its nudge.
        var lapsed: Set<ReminderItem.Kind> = []
    }
    struct Existing: Sendable {
        var id: String
        var title: String
        var due: String
        var notes: String
        var path: String
        var completed: Bool
    }
    struct Change: Sendable {
        var existingID: String?
        var item: ReminderItem
        var notes: String
    }
    struct Plan: Sendable {
        var saves: [Change] = []
        var removes: [String] = []
    }
    struct Ambiguous: Error, LocalizedError {
        var errorDescription: String? { "More than one reminder matches this document. Resolve the duplicate reminders before retrying." }
    }
    static func marker(_ id: String, _ kind: ReminderItem.Kind, app: String = "HomeClerk") -> String {
        "[\(app):v1:\(Data(id.utf8).base64EncodedString()):\(kind.rawValue)]"
    }
    /// Reminders made before the rename carry the old app name in their marker; they're still this
    /// document's, and get the new marker the next time they're saved.
    static func owns(_ reminder: Existing, id: String, kind: ReminderItem.Kind) -> Bool {
        let last = reminder.notes.components(separatedBy: "\n").last
        return last == marker(id, kind) || last == marker(id, kind, app: Legacy.reminderMarkerApp)
    }
    static func legacyMatches(_ reminder: Existing, item: ReminderItem) -> Bool {
        reminder.title == item.title && reminder.due == item.due && reminder.notes == item.notes && reminder.path == item.filePath
    }
    static func plan(_ request: Request, existing: [Existing]) throws -> Plan {
        guard let id = request.documentID, !id.isEmpty else { return Plan() }
        var result = Plan()
        var claimed = Set<String>()
        for kind in ReminderItem.Kind.allCases {
            let desired = request.items.filter { $0.kind == kind }
            guard desired.count <= 1 else { throw Ambiguous() }
            let candidates = existing.filter { reminder in
                owns(reminder, id: id, kind: kind) ||
                (request.previous + request.items).contains { $0.kind == kind && legacyMatches(reminder, item: $0) }
            }
            guard candidates.count <= 1 else { throw Ambiguous() }
            let old = candidates.first
            if let old { guard claimed.insert(old.id).inserted else { throw Ambiguous() } }
            if let item = desired.first {
                let notes = item.notes + "\n" + marker(id, kind)
                if old?.title != item.title || old?.due != item.due || old?.notes != notes || old?.path != item.filePath {
                    result.saves.append(Change(existingID: old?.id, item: item, notes: notes))
                }
            } else if let old, !request.lapsed.contains(kind) { result.removes.append(old.id) }
        }
        return result
    }
}
