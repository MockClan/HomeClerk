import Foundation

/// A reminder to create for a filed document.
public struct ReminderItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case payment, expiration }
    public var title: String
    /// yyyy-MM-dd
    public var due: String
    public var notes: String
    public var filePath: String
    public var kind: Kind = .payment
}

/// Decides the Finder tags and reminders for a filed document from its facets. Pure logic, so it
/// can be tested without touching Finder or Reminders.
public enum FinishingPlan {
    /// Tags that make a document findable across folders: its area, who or what it's about, and its
    /// facet tags — e.g. "Vehicle", "2021 Toyota RAV4", "Tolls".
    public static func finderTags(_ facets: DocumentFacets) -> [String] {
        var tags: [String] = []
        func add(_ value: String) {
            let label = readable(value)
            if !label.isEmpty, !tags.contains(where: { TextRules.equalsIgnoringCase($0, label) }) { tags.append(label) }
        }
        if !TextRules.equalsIgnoringCase(facets.area, "Other") { add(facets.area) }
        add(facets.person)
        add(facets.vehicle)
        add(facets.pet)
        for tag in facets.tags { add(titleCase(tag)) }
        return tags
    }

    /// "Pay Prairie Gas $77.05" — the reminder for a bill with an amount; nil without one.
    public static func paymentReminderTitle(_ facets: DocumentFacets) -> String? {
        facets.amount.map { "Pay \(readable(facets.vendor)) \(currency($0))" }
    }

    /// A payment reminder on a bill's due date, and a heads-up `expirationLeadDays` before anything
    /// expires (policies, registrations, vaccinations, warranties). Dates already past are skipped.
    /// `today` is yyyy-MM-dd.
    public static func reminders(_ facets: DocumentFacets, filePath: String, today: String, expirationLeadDays: Int,
                                 includingOverduePayments: Bool = false)
        -> [ReminderItem] {
        var reminders: [ReminderItem] = []
        let vendor = readable(facets.vendor)
        let what = readable(facets.description).isEmpty ? "Document" : readable(facets.description)
        let notes = vendor.isEmpty ? what : "\(what) from \(vendor)"

        if let due = day(facets.dueDate), let now = day(today), includingOverduePayments || due >= now,
           let title = paymentReminderTitle(facets) {
            reminders.append(ReminderItem(title: title, due: format(due), notes: notes, filePath: filePath))
        }

        if let expires = day(facets.expiresOn), let now = day(today), expires > now {
            let subject = [facets.pet, facets.vehicle, facets.person].map(readable).first { !$0.isEmpty } ?? vendor
            var remindOn = calendar.date(byAdding: .day, value: -expirationLeadDays, to: expires)!
            if remindOn < now { remindOn = now }
            let expiry = "\(what) expires \(display(expires))"
            reminders.append(ReminderItem(title: subject.isEmpty ? expiry : "\(subject): \(expiry)", due: format(remindOn),
                                          notes: notes, filePath: filePath, kind: .expiration))
        }
        return reminders
    }

    /// Reminder kinds whose date has passed — kept, not removed, when a correction resynchronizes
    /// reminders. (Overdue payments are kept as wanted items instead.)
    static func lapsedReminderKinds(_ facets: DocumentFacets, today: String) -> Set<ReminderItem.Kind> {
        guard let expires = day(facets.expiresOn), let now = day(today), expires <= now else { return [] }
        return [.expiration]
    }

    public static func readable(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "data-breach" → "Data Breach", "w2" → "W2".
    static func titleCase(_ tag: String) -> String {
        tag.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Strict yyyy-MM-dd, as midnight here — for showing and counting days on this Mac's calendar.
    public static func localDay(_ value: String) -> Date? {
        guard let utc = day(value) else { return nil }
        return Calendar.current.date(from: calendar.dateComponents([.year, .month, .day], from: utc))
    }

    /// Looks like yyyy-MM-dd (digits and dashes in the right places), without checking it's a real
    /// date — cheap enough for sorting, where yyyy-MM-dd strings already order by date.
    public static func isDayShaped(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10 else { return false }
        for (i, byte) in bytes.enumerated() {
            if i == 4 || i == 7 { guard byte == UInt8(ascii: "-") else { return false } }
            else { guard byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") else { return false } }
        }
        return true
    }

    /// Strict yyyy-MM-dd, as a UTC midnight.
    public static func day(_ value: String) -> Date? {
        guard isDayShaped(value) else { return nil }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
        return date
    }

    static func format(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// "Mar 9, 2026"
    static func display(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    /// US dollars: "$1,234.50", "-$12.35".
    public static func currency(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.negativePrefix = "-$"
        // Half a cent rounds away from zero, as file names always have (the default rounds to even)
        formatter.roundingMode = .halfUp
        return formatter.string(from: amount as NSDecimalNumber) ?? "$\(amount)"
    }
}
