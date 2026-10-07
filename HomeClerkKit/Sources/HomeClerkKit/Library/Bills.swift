import Foundation

// Bills: whether each one is paid, whether it's higher than usual, and what was spent. Paid comes
// from automatic or confirmed receipt links, or from marking it by hand; hand marks win.

/// How a bill came to be paid — or that it isn't.
public enum BillPayment: Equatable, Sendable {
    case unpaid
    /// Marked paid by hand (Upcoming ▸ Paid).
    case markedPaid
    /// An automatic or explicitly confirmed receipt link; its current path.
    case receipt(String)

    public var isPaid: Bool { self != .unpaid }
}

/// Bills marked paid or not paid by hand, in paid.json beside household.json. Paths are retained
/// for old-file compatibility; new marks belong to a persistent document ID.
public final class PaidMarks: @unchecked Sendable {
    public static let fileName = "paid.json"

    struct Mark: Codable, Equatable, Sendable {
        var paid: Bool
        var identity: String? // Retained only to decode older paid.json files; never used to match.
        var documentID: String? = nil
        var at: Date
    }

    public let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    /// The hand mark for a bill: true paid, false not paid (overriding a matched receipt), nil none.
    public func mark(for bill: DocumentIndex.Entry) -> Bool? { snapshot().mark(for: bill) }

    /// Every mark, read once — for looking up many bills.
    public func snapshot() -> Snapshot { Snapshot(marks: lock.withLock { read() }) }

    public struct Snapshot: Sendable {
        let marks: [String: Mark]
        let byDocument: [String: Mark]

        init(marks: [String: Mark]) {
            self.marks = marks
            byDocument = Dictionary(marks.values.compactMap { mark in mark.documentID.map { ($0, mark) } },
                                    uniquingKeysWith: { a, b in a.at > b.at ? a : b })
        }

        public func mark(for bill: DocumentIndex.Entry) -> Bool? {
            if let mark = byDocument[bill.documentID] { return mark.paid }
            // A legacy mark is safe only at its recorded path on a legacy document. Do not
            // guess across renames, or apply it to a newly filed document reusing that path.
            if bill.documentID.hasPrefix("legacy-"), let mark = marks[bill.path], mark.documentID == nil {
                return mark.paid
            }
            return nil
        }
    }

    /// Marks a bill paid or not paid; nil clears the mark, leaving it to receipts.
    public func set(_ paid: Bool?, for bill: DocumentIndex.Entry) throws {
        try lock.withLock {
            var marks = read()
            marks = marks.filter { $0.value.documentID != bill.documentID
                && !($0.key == bill.path && $0.value.documentID == nil) }
            if let paid { marks["document:" + bill.documentID] = Mark(paid: paid, documentID: bill.documentID, at: Date()) }
            try PrivateFile.writeJSON(marks, to: url)
        }
    }

    /// Upgrade an old path-based mark before a correction changes the document's path.
    public func migrateLegacyMark(for bill: DocumentIndex.Entry) throws {
        try lock.withLock {
            var marks = read()
            guard bill.documentID.hasPrefix("legacy-"), var mark = marks[bill.path], mark.documentID == nil else { return }
            mark.documentID = bill.documentID
            marks[bill.path] = nil
            marks["document:" + bill.documentID] = mark
            try PrivateFile.writeJSON(marks, to: url)
        }
    }

    private func read() -> [String: Mark] { PrivateFile.readJSON([String: Mark].self, from: url) ?? [:] }

}

public enum Bills {
    /// A receipt can pay a bill issued up to this many days before it is due…
    static let receiptDaysBeforeDue = 60
    /// …and paid up to this many days late.
    static let receiptDaysAfterDue = 45

    /// "Acme_Power_Co" and "ACME Power Co." both become "acmepowerco".
    public static func vendorKey(_ vendor: String) -> String {
        String(vendor.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    /// Anything with a due date can be paid: bills, and statements with a payment due.
    static func isPayable(_ entry: DocumentIndex.Entry) -> Bool {
        FinishingPlan.isDayShaped(entry.facets.dueDate)
    }

    /// A bill with an amount — what counts as spending and has a usual amount.
    static func isBill(_ entry: DocumentIndex.Entry) -> Bool {
        entry.facets.documentType == "Bill" && (entry.facets.amount ?? 0) > 0
    }

    static func isReceipt(_ entry: DocumentIndex.Entry) -> Bool {
        entry.facets.documentType == "Receipt" && (entry.facets.amount ?? 0) > 0
    }

    /// The day a document is about: its date, or for a bill without one, its due date.
    static func day(_ entry: DocumentIndex.Entry) -> String {
        FinishingPlan.isDayShaped(entry.facets.documentDate) ? entry.facets.documentDate : entry.facets.dueDate
    }

    /// Pairs receipts with the bills they paid (see `BillIndex.receiptMatches`). Bill path → receipt path.
    public static func receiptMatches(_ documents: [DocumentIndex.Entry], decisions: ReceiptDecisions.Snapshot = .empty) -> [String: String] {
        BillIndex(documents, decisions: decisions).receiptMatches
    }

    /// The typical amount from a vendor (see `BillIndex.usualAmount`).
    public static func usualAmount(before bill: DocumentIndex.Entry, in documents: [DocumentIndex.Entry]) -> Decimal? {
        BillIndex(documents).usualAmount(before: bill)
    }

    /// The usual amount when this bill is noticeably more (see `BillIndex.higherThanUsual`).
    public static func higherThanUsual(_ bill: DocumentIndex.Entry, in documents: [DocumentIndex.Entry]) -> Decimal? {
        BillIndex(documents).higherThanUsual(bill)
    }

    /// What a newly filed document means for bills, for its notification and Activity: a bill
    /// higher than usual, or a receipt that pays a bill not already marked by hand.
    public static func filingNote(for path: String, in documents: [DocumentIndex.Entry], marks: PaidMarks?, decisions: ReceiptDecisions.Snapshot = .empty) -> String? {
        guard let entry = documents.first(where: { $0.path == path }) else { return nil }
        let index = BillIndex(documents, decisions: decisions)
        if let usual = index.higherThanUsual(entry) {
            return "Higher than usual: \(FinishingPlan.readable(entry.facets.vendor)) is usually about \(FinishingPlan.currency(usual))"
        }
        if let billPath = index.receiptMatches.first(where: { $0.value == path })?.key,
           let bill = documents.first(where: { $0.path == billPath }), marks?.mark(for: bill) == nil {
            return "Pays the \(FinishingPlan.readable(bill.facets.vendor)) bill due \(bill.facets.dueDate)"
        }
        return nil
    }
}

/// Bills and receipts grouped by vendor, made once per look at the library, so checking one bill
/// only looks at that vendor's documents rather than all of them.
public struct BillIndex: Sendable {
    /// One bill in a vendor's history.
    private struct Past: Sendable {
        var day: String
        var amount: Decimal
        var path: String
    }

    /// Bills with amounts, newest first — the history "usual" is measured against.
    private let billsByVendor: [String: [Past]]
    /// Bill path → the receipt that paid it.
    public let receiptMatches: [String: String]

    public let proposals: [ReceiptMatchProposal]

    public init(_ documents: [DocumentIndex.Entry], decisions: ReceiptDecisions.Snapshot = .empty) {
        let identities = Dictionary(grouping: documents, by: \.documentID)
        let paths = Dictionary(grouping: documents, by: \.path)
        let documents = documents.filter { identities[$0.documentID]?.count == 1 && paths[$0.path]?.count == 1 }
        let grouped = Dictionary(grouping: documents) { Bills.vendorKey($0.facets.vendor) }.filter { !$0.key.isEmpty }
        billsByVendor = grouped.mapValues { entries in
            entries.filter(Bills.isBill)
                .map { Past(day: Bills.day($0), amount: $0.facets.amount ?? 0, path: $0.path) }
                .sorted { $0.day > $1.day }
        }
        let candidates = grouped.values.flatMap { Self.candidates($0) }
        let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.documentID, $0) })
        let confirmed = decisions.records.filter(\.confirmed)
        let reservedBills = Set(confirmed.map(\.billID)), reservedReceipts = Set(confirmed.map(\.receiptID))
        var matches: [String: String] = [:]
        if decisions.available {
            for record in confirmed {
                if let bill = byID[record.billID], let receipt = byID[record.receiptID],
                   Bills.isPayable(bill), !Bills.isReceipt(bill), (bill.facets.amount ?? 0) > 0, Bills.isReceipt(receipt) {
                    matches[bill.path] = receipt.path
                }
            }
            let eligible = candidates.filter { pair in
                pair.strict && !reservedBills.contains(pair.bill.documentID) && !reservedReceipts.contains(pair.receipt.documentID) &&
                decisions.decision(billID: pair.bill.documentID, receiptID: pair.receipt.documentID) != false
            }
            for pair in Self.closestPairs(eligible) { matches[pair.bill.path] = pair.receipt.path }
        }
        receiptMatches = matches
        var pairs = Dictionary(uniqueKeysWithValues: candidates.map { (ReceiptDecisions.Record.key($0.bill.documentID, $0.receipt.documentID), $0) })
        // Keep saved decisions reviewable after metadata changes make them ineligible proposals.
        for record in decisions.records {
            if let bill = byID[record.billID], let receipt = byID[record.receiptID], pairs[record.id] == nil {
                pairs[record.id] = Candidate(bill: bill, receipt: receipt, strict: false, reasons: ["Current details no longer meet automatic matching rules."])
            }
        }
        // A bill or receipt already paired with a better fit settles its other pairings; listing
        // them as needing review would ask about pairs that are resolved. Saved decisions stay.
        let pairedBills = Set(matches.keys), pairedReceipts = Set(matches.values)
        proposals = pairs.values.filter { pair in
            matches[pair.bill.path] == pair.receipt.path
                || decisions.decision(billID: pair.bill.documentID, receiptID: pair.receipt.documentID) != nil
                || !(pairedBills.contains(pair.bill.path) || pairedReceipts.contains(pair.receipt.path))
        }.map { pair in
            let decision = decisions.decision(billID: pair.bill.documentID, receiptID: pair.receipt.documentID)
            let active = matches[pair.bill.path] == pair.receipt.path
            let status: ReceiptMatchProposal.Status = decision == true ? .confirmed : decision == false ? .rejected : active ? .automatic : .suggested
            let reserved = (reservedBills.contains(pair.bill.documentID) || reservedReceipts.contains(pair.receipt.documentID)) && decision != true
            var reasons = pair.reasons
            if decisions.available && pair.strict && status == .suggested && !reserved { reasons.append("More than one eligible pairing exists; no automatic payment was inferred.") }
            if reserved { reasons.append("A document in this pair is confirmed with another document. Reset that decision first.") }
            if decision == true && !active { reasons.append("The saved confirmation is inactive while the documents lack a payable bill/receipt amount or type.") }
            if !decisions.available { reasons.append("Decision history is unreadable. Receipt matching is suspended.") }
            return ReceiptMatchProposal(bill: pair.bill, receipt: pair.receipt, status: status, reasons: reasons,
                canConfirm: decisions.available && !reserved && Bills.isPayable(pair.bill) && !Bills.isReceipt(pair.bill) &&
                    (pair.bill.facets.amount ?? 0) > 0 && Bills.isReceipt(pair.receipt), active: active)
        }.sorted { ($0.bill.facets.dueDate, $0.bill.path, $0.receipt.path) < ($1.bill.facets.dueDate, $1.bill.path, $1.receipt.path) }
    }

    private struct Candidate {
        var bill: DocumentIndex.Entry
        var receipt: DocumentIndex.Entry
        var strict: Bool
        var reasons: [String]

        /// Days between the receipt and the bill's due date: how well they fit each other.
        var distance: Int {
            guard let due = FinishingPlan.day(bill.facets.dueDate), let paid = FinishingPlan.day(Bills.day(receipt)) else { return .max }
            return abs(FinishingPlan.calendar.dateComponents([.day], from: due, to: paid).day ?? .max)
        }
    }

    /// Pairs each receipt with the bill whose due date it's closest to, best fits first, each used
    /// once — so two months of the same fixed bill pair up month by month, and a missed month stays
    /// unpaid rather than borrowing the next month's receipt. When a receipt fits two bills (or a
    /// bill two receipts) equally well, neither is paid automatically; they stay suggestions.
    private static func closestPairs(_ eligible: [Candidate]) -> [Candidate] {
        let ranked = eligible.map { ($0, $0.distance) }.sorted { a, b in
            (a.1, a.0.bill.facets.dueDate, a.0.bill.path, a.0.receipt.path) < (b.1, b.0.bill.facets.dueDate, b.0.bill.path, b.0.receipt.path)
        }
        var usedBills = Set<String>(), usedReceipts = Set<String>(), tied = Set<String>()
        var chosen: [Candidate] = []
        for (pair, distance) in ranked {
            let bill = pair.bill.documentID, receipt = pair.receipt.documentID
            guard !usedBills.contains(bill), !usedReceipts.contains(receipt), !tied.contains(bill), !tied.contains(receipt) else { continue }
            // Another still-open pairing for this bill or receipt fits exactly as well: ambiguous
            let rivals = ranked.filter { other, otherDistance in
                otherDistance == distance && (other.bill.documentID == bill) != (other.receipt.documentID == receipt)
                    && !usedBills.contains(other.bill.documentID) && !usedReceipts.contains(other.receipt.documentID)
                    && !tied.contains(other.bill.documentID) && !tied.contains(other.receipt.documentID)
            }
            if !rivals.isEmpty {
                // Only the contested receipt (or bill) is ambiguous; the others may still pair elsewhere
                for (other, _) in rivals { tied.insert(other.bill.documentID == bill ? bill : receipt) }
                continue
            }
            usedBills.insert(bill)
            usedReceipts.insert(receipt)
            chosen.append(pair)
        }
        return chosen
    }

    /// Proposals share vendor/amount/date evidence. Subject mismatches require a human decision;
    /// only strict, mutually unique pairs become automatic payments.
    private static func candidates(_ documents: [DocumentIndex.Entry]) -> [Candidate] {
        let bills = documents.filter { Bills.isPayable($0) && !Bills.isReceipt($0) && ($0.facets.amount ?? 0) > 0 }
        let receipts = documents.filter(Bills.isReceipt)
            .compactMap { receipt in FinishingPlan.day(Bills.day(receipt)).map { (receipt, $0) } }
        // Which people, vehicles, and pets this vendor's documents mention. With more than one (two
        // cars on one insurer), a receipt naming none could belong to either.
        let mentioned = SubjectsMentioned(documents)
        var result: [Candidate] = []
        for bill in bills {
            guard let due = FinishingPlan.day(bill.facets.dueDate) else { continue }
            let earliest = FinishingPlan.calendar.date(byAdding: .day, value: -Bills.receiptDaysBeforeDue, to: due)!
            let latest = FinishingPlan.calendar.date(byAdding: .day, value: Bills.receiptDaysAfterDue, to: due)!
            let issued = FinishingPlan.day(bill.facets.documentDate)
            for (receipt, paid) in receipts where receipt.path != bill.path && receipt.facets.amount == bill.facets.amount &&
                paid >= earliest && paid <= latest && (issued.map { paid >= $0 } ?? true) {
                var reasons = ["Same normalized vendor and amount.", "Receipt date is within 60 days before / 45 days after the due date, and does not precede a known bill issue date."]
                let fields = [("Person", bill.facets.person, receipt.facets.person, mentioned.people),
                              ("Vehicle", bill.facets.vehicle, receipt.facets.vehicle, mentioned.vehicles),
                              ("Pet", bill.facets.pet, receipt.facets.pet, mentioned.pets)]
                let problems = fields.compactMap { label, a, b, known in subjectProblem(label, bill: a, receipt: b, vendorMentions: known) }
                let same = problems.isEmpty
                if same { reasons.append("Person, vehicle, and pet don't conflict.") } else { reasons += problems }
                result.append(Candidate(bill: bill, receipt: receipt, strict: same, reasons: reasons))
            }
        }
        return result
    }

    /// Why a person, vehicle, or pet keeps this from being an automatic match; nil when it doesn't.
    /// Two different names always need confirming. A blank on one side is "not stated" — most
    /// receipts name no one — and fits, unless this vendor's documents mention more than one
    /// (two cars on one insurer), when it could belong to either.
    private static func subjectProblem(_ label: String, bill: String, receipt: String, vendorMentions: Set<String>) -> String? {
        let a = TextRules.key(bill), b = TextRules.key(receipt)
        if a == b { return nil }
        if !a.isEmpty && !b.isEmpty {
            return "\(label) differs: bill ‘\(FinishingPlan.readable(bill))’, receipt ‘\(FinishingPlan.readable(receipt))’. Verify the PDFs before confirming."
        }
        guard vendorMentions.count > 1 else { return nil }
        let stated = FinishingPlan.readable(a.isEmpty ? receipt : bill)
        return "\(label): only the \(a.isEmpty ? "receipt" : "bill") says ‘\(stated)’, and this vendor's documents mention \(vendorMentions.count) different ones. Verify the PDFs before confirming."
    }

    /// The distinct people, vehicles, and pets named in one vendor's documents.
    private struct SubjectsMentioned {
        var people = Set<String>(), vehicles = Set<String>(), pets = Set<String>()

        init(_ documents: [DocumentIndex.Entry]) {
            for d in documents {
                for (value, keyPath) in [(d.facets.person, \Self.people), (d.facets.vehicle, \Self.vehicles), (d.facets.pet, \Self.pets)] {
                    let key = TextRules.key(value)
                    if !key.isEmpty { self[keyPath: keyPath].insert(key) }
                }
            }
        }
    }

    /// The typical amount from a vendor: the median of up to its six bills before `bill`, when
    /// there are at least three to go on.
    public func usualAmount(before bill: DocumentIndex.Entry) -> Decimal? {
        let when = Bills.day(bill)
        let earlier = (billsByVendor[Bills.vendorKey(bill.facets.vendor)] ?? [])
            .lazy.filter { $0.path != bill.path && $0.day < when }
            .prefix(6)
            .map(\.amount)
            .sorted()
        guard earlier.count >= 3 else { return nil }
        let middle = earlier.count / 2
        return earlier.count.isMultiple(of: 2) ? (earlier[middle - 1] + earlier[middle]) / 2 : earlier[middle]
    }

    /// The usual amount when this bill is at least a quarter and $10 more than it; nil otherwise.
    public func higherThanUsual(_ bill: DocumentIndex.Entry) -> Decimal? {
        guard Bills.isBill(bill), let amount = bill.facets.amount,
              let usual = usualAmount(before: bill), usual > 0,
              amount >= usual * Decimal(string: "1.25")!, amount - usual >= 10 else { return nil }
        return usual
    }
}

// MARK: - Spending

/// Money spent in one month for one vendor or area.
public struct SpendingRow: Equatable, Sendable, Identifiable {
    /// yyyy-MM
    public var month: String
    /// A readable vendor or area name.
    public var group: String
    public var amount: Decimal
    public var documents: Int
    public var id: String { "\(month) \(group)" }

    public init(month: String, group: String, amount: Decimal, documents: Int) {
        self.month = month
        self.group = group
        self.amount = amount
        self.documents = documents
    }
}

public enum SpendingGrouping: String, CaseIterable, Sendable {
    case vendor = "Vendor", area = "Category"
}

extension DocumentLibrary {
    /// How each bill stands: hand marks first, then matched receipts.
    public func payments(marks: PaidMarks?, decisions: ReceiptDecisions.Snapshot = .empty) -> [String: BillPayment] {
        let matched = BillIndex(documents, decisions: decisions).receiptMatches
        let snapshot = marks?.snapshot()
        var payments: [String: BillPayment] = [:]
        for bill in documents where Bills.isPayable(bill) {
            switch snapshot?.mark(for: bill) {
            case true?: payments[bill.path] = .markedPaid
            case false?: payments[bill.path] = .unpaid
            case nil: payments[bill.path] = matched[bill.path].map(BillPayment.receipt) ?? .unpaid
            }
        }
        return payments
    }

    /// Spending by month from `from` through `to` (yyyy-MM-dd): bills, plus receipts that didn't pay
    /// a bill (paying a bill isn't spending twice). Statements are left out — their amounts are
    /// balances. Largest first within each month.
    public func spending(from: String, to: String, by grouping: SpendingGrouping, decisions: ReceiptDecisions.Snapshot = .empty) -> [SpendingRow] {
        let spendingBills = Set(documents.filter { Bills.isBill($0) && FinishingPlan.day(Bills.day($0)) != nil }.map(\.path))
        let paidBy = Set(BillIndex(documents, decisions: decisions).receiptMatches.filter { spendingBills.contains($0.key) }.values)
        var totals: [String: SpendingRow] = [:]
        for d in documents where Bills.isBill(d) || (Bills.isReceipt(d) && !paidBy.contains(d.path)) {
            let day = Bills.day(d)
            guard FinishingPlan.day(day) != nil, day >= from, day <= to, let amount = d.facets.amount else { continue }
            let month = String(day.prefix(7))
            let raw = grouping == .vendor ? d.facets.vendor : d.facets.area
            let group = FinishingPlan.readable(raw).isEmpty ? "Unknown" : FinishingPlan.readable(raw)
            // Vendors spelled two ways still add up together
            let key = month + " " + (grouping == .vendor ? Bills.vendorKey(raw) : group)
            var row = totals[key] ?? SpendingRow(month: month, group: group, amount: 0, documents: 0)
            row.amount += amount
            row.documents += 1
            totals[key] = row
        }
        return totals.values.sorted { ($0.month, $1.amount, $0.group) < ($1.month, $0.amount, $1.group) }
    }
}

extension SpendingRow {
    /// Month, vendor or category, amount, and documents, a row per line, for a spreadsheet. Names
    /// read from documents go through the tax export's formula guard.
    public static func csv(_ rows: [SpendingRow], grouping: SpendingGrouping) -> String {
        let amount = NumberFormatter()
        amount.locale = Locale(identifier: "en_US_POSIX")
        amount.minimumFractionDigits = 2
        amount.maximumFractionDigits = 2
        amount.minimumIntegerDigits = 1
        var lines = ["Month,\(grouping.rawValue),Amount,Documents"]
        for row in rows {
            lines.append([row.month, TaxPacket.csvField(row.group), amount.string(from: row.amount as NSDecimalNumber) ?? "\(row.amount)",
                          "\(row.documents)"].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
