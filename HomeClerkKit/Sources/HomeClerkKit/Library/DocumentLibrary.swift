import Foundation

/// A date something needs attention: a bill due or a document expiring.
public struct UpcomingItem: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case due = "Due", expires = "Expires" }
    /// yyyy-MM-dd
    public var date: String
    public var kind: Kind
    public var title: String
    public var path: String
    /// For a bill: whether it's paid, and how. Nil for expirations.
    public var payment: BillPayment? = nil
    /// For a bill noticeably more than this vendor's usual: the usual amount.
    public var usual: Decimal? = nil
    public var id: String { "\(date) \(kind.rawValue) \(path)" }
}

/// Read-side view of index.jsonl: the newest entry for each filed document that still exists, for
/// answering "what's due?" and "find everything about X" without the AI.
public struct DocumentLibrary: Sendable {
    public let documents: [DocumentIndex.Entry]

    public init(documents: [DocumentIndex.Entry]) { self.documents = documents }

    /// Loads the index; later lines win, and entries for moved or deleted files are dropped.
    public static func load(_ index: DocumentIndex) -> DocumentLibrary {
        var latest: [String: DocumentIndex.Entry] = [:]
        var order: [String] = []
        for entry in index.load() {
            if latest[entry.path] == nil { order.append(entry.path) }
            latest[entry.path] = entry
        }
        return DocumentLibrary(documents: order.compactMap { latest[$0] }
            .filter { !$0.removed && FileManager.default.fileExists(atPath: $0.path) })
    }

    /// Due dates and expirations from `from` through `to` (yyyy-MM-dd), soonest first. With
    /// `overdueFrom`, unpaid bills due from then until `from` are included too.
    public func upcoming(from: String, to: String, payments: [String: BillPayment] = [:],
                         overdueFrom: String? = nil) -> [UpcomingItem] {
        var items: [UpcomingItem] = []
        let bills = BillIndex(documents)
        for d in documents {
            let f = d.facets
            let vendor = FinishingPlan.readable(f.vendor)
            let what = FinishingPlan.readable(f.description)
            let payment = payments[d.path]
            let overdue = overdueFrom.map { f.dueDate >= $0 && f.dueDate < from && payment?.isPaid != true } ?? false
            if FinishingPlan.day(f.dueDate) != nil, (f.dueDate >= from && f.dueDate <= to) || overdue {
                let amount = f.amount.map { " " + FinishingPlan.currency($0) } ?? ""
                items.append(UpcomingItem(date: f.dueDate, kind: .due, title: "\(vendor)\(amount) — \(what)", path: d.path,
                                          payment: payment, usual: bills.higherThanUsual(d)))
            }
            if FinishingPlan.day(f.expiresOn) != nil, f.expiresOn >= from, f.expiresOn <= to {
                let subject = [f.pet, f.vehicle, f.person].map(FinishingPlan.readable).first { !$0.isEmpty }
                items.append(UpcomingItem(date: f.expiresOn, kind: .expires,
                                          title: subject.map { "\($0): \(what) (\(vendor))" } ?? "\(what) (\(vendor))",
                                          path: d.path))
            }
        }
        return items.sorted { ($0.date, $0.title) < ($1.date, $1.title) }
    }

    /// Documents matching every search word (case-insensitive) in any of their facets, summary,
    /// or file name; newest first.
    public func find(_ query: String) -> [DocumentIndex.Entry] {
        let words = query.split(separator: " ").map { Self.normalize(String($0)) }
        guard !words.isEmpty else { return [] }
        return documents.filter { d in
            let text = Self.searchText(d)
            return words.allSatisfy(text.contains)
        }.sorted { $0.facets.documentDate > $1.facets.documentDate }
    }

    static func searchText(_ d: DocumentIndex.Entry) -> String {
        let f = d.facets
        return normalize([f.area, f.documentType, f.tags.joined(separator: " "), f.vendor, f.description, f.person,
                          f.vehicle, f.pet, f.documentDate, d.summary, (d.path as NSString).lastPathComponent]
            .joined(separator: " "))
    }

    /// Underscores and hyphens become spaces, so "rav4" matches "2021_Toyota_RAV4".
    static func normalize(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").lowercased()
    }
}
