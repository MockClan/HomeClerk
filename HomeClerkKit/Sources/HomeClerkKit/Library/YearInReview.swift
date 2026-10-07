import Foundation

/// A year of household paperwork at a glance: what was filed, what was spent and with whom, how
/// bills were paid, which vendors got dearer, and what expired. Computed from the library alone.
public struct YearInReview: Equatable, Sendable {
    public struct Count: Equatable, Sendable {
        public var name: String
        public var count: Int
    }

    public struct Amount: Equatable, Sendable {
        public var name: String
        public var amount: Decimal
    }

    /// A vendor whose bills averaged more this year than last.
    public struct Change: Equatable, Sendable {
        public var vendor: String
        public var lastYear: Decimal
        public var thisYear: Decimal
        /// 0.12 for 12% more.
        public var increase: Double
    }

    public var year: Int
    public var documents: Int
    /// Documents by category (area), most first.
    public var byArea: [Count]
    /// yyyy-MM and how many documents are dated in it; nil without any.
    public var busiestMonth: Count?
    /// Bills plus receipts that didn't pay a bill, as in Spending.
    public var spent: Decimal
    /// The vendors spent most with, most first (up to five).
    public var topVendors: [Amount]
    public var largestBill: Amount?
    /// Bills paid by a matched receipt, and how many of those were paid by their due date.
    public var billsPaidByReceipt: Int
    public var paidOnTime: Int
    /// Vendors whose average bill rose at least 5% from the year before, largest rise first.
    public var priceRises: [Change]
    /// Documents that expired during the year.
    public var expired: [String]

    /// Years with documents dated in them, newest first.
    public static func years(in library: DocumentLibrary) -> [Int] {
        Set(library.documents.compactMap { Int(Bills.day($0).prefix(4)) }.filter { $0 > 1900 }).sorted(by: >)
    }

    public init(year: Int, library: DocumentLibrary, decisions: ReceiptDecisions.Snapshot = .empty) {
        let prefix = String(format: "%04d", year)
        let documents = library.documents
        let inYear = documents.filter { Bills.day($0).hasPrefix(prefix) }
        self.year = year
        self.documents = inYear.count

        func ranked(_ counts: [String: Int]) -> [Count] {
            counts.map { Count(name: $0.key, count: $0.value) }.sorted { ($1.count, $0.name) < ($0.count, $1.name) }
        }
        byArea = ranked(Dictionary(grouping: inYear) { FinishingPlan.readable($0.facets.area).isEmpty ? "Other" : FinishingPlan.readable($0.facets.area) }
            .mapValues(\.count))
        busiestMonth = ranked(Dictionary(grouping: inYear) { String(Bills.day($0).prefix(7)) }.mapValues(\.count)).first

        let spending = library.spending(from: "\(prefix)-01-01", to: "\(prefix)-12-31", by: .vendor, decisions: decisions)
        spent = spending.reduce(0) { $0 + $1.amount }
        var byVendor: [String: Decimal] = [:]
        for row in spending { byVendor[row.group, default: 0] += row.amount }
        topVendors = Array(byVendor.map { Amount(name: $0.key, amount: $0.value) }
            .sorted { ($1.amount, $0.name) < ($0.amount, $1.name) }.prefix(5))

        let bills = inYear.filter(Bills.isBill)
        largestBill = bills.max { ($0.facets.amount ?? 0) < ($1.facets.amount ?? 0) }.map {
            Amount(name: FinishingPlan.readable($0.facets.vendor), amount: $0.facets.amount ?? 0)
        }

        let matches = BillIndex(documents, decisions: decisions).receiptMatches
        let byPath = Dictionary(documents.map { ($0.path, $0) }, uniquingKeysWith: { $1 })
        let paidThisYear = inYear.filter { Bills.isPayable($0) && matches[$0.path] != nil }
        billsPaidByReceipt = paidThisYear.count
        paidOnTime = paidThisYear.filter { bill in
            guard let receipt = matches[bill.path].flatMap({ byPath[$0] }) else { return false }
            return Bills.day(receipt) <= bill.facets.dueDate
        }.count

        let lastPrefix = String(format: "%04d", year - 1)
        func averages(_ yearPrefix: String) -> [String: (name: String, average: Decimal)] {
            let grouped = Dictionary(grouping: documents.filter { Bills.isBill($0) && Bills.day($0).hasPrefix(yearPrefix) }) {
                Bills.vendorKey($0.facets.vendor)
            }
            return grouped.compactMapValues { bills in
                guard let first = bills.first, !bills.isEmpty else { return nil }
                let total = bills.reduce(Decimal(0)) { $0 + ($1.facets.amount ?? 0) }
                return (FinishingPlan.readable(first.facets.vendor), total / Decimal(bills.count))
            }
        }
        let now = averages(prefix), before = averages(lastPrefix)
        priceRises = now.compactMap { key, current -> Change? in
            guard let previous = before[key], previous.average > 0 else { return nil }
            let rise = ((current.average - previous.average) / previous.average as NSDecimalNumber).doubleValue
            guard rise >= 0.05 else { return nil }
            return Change(vendor: current.name, lastYear: previous.average, thisYear: current.average, increase: rise)
        }.sorted { ($1.increase, $0.vendor) < ($0.increase, $1.vendor) }

        expired = documents.filter { $0.facets.expiresOn.hasPrefix(prefix) && FinishingPlan.isDayShaped($0.facets.expiresOn) }
            .sorted { $0.facets.expiresOn < $1.facets.expiresOn }
            .map { d in
                let subject = [d.facets.pet, d.facets.vehicle, d.facets.person].map(FinishingPlan.readable).first { !$0.isEmpty }
                let what = FinishingPlan.readable(d.facets.description)
                return (subject.map { "\($0): " } ?? "") + (what.isEmpty ? "Document" : what) + " (\(d.facets.expiresOn))"
            }
    }

    /// The summary as plain text, for Copy Summary.
    public var text: String {
        var lines = ["\(year) in paperwork", ""]
        lines.append("\(documents) document\(documents == 1 ? "" : "s") filed"
                     + (byArea.isEmpty ? "" : ": " + byArea.prefix(4).map { "\($0.count) \($0.name)" }.joined(separator: ", ")))
        if let busiestMonth { lines.append("Busiest month: \(busiestMonth.name) (\(busiestMonth.count))") }
        lines.append("Spent: \(FinishingPlan.currency(spent))")
        if !topVendors.isEmpty {
            lines.append("Top vendors: " + topVendors.map { "\($0.name) \(FinishingPlan.currency($0.amount))" }.joined(separator: ", "))
        }
        if let largestBill { lines.append("Largest bill: \(largestBill.name) \(FinishingPlan.currency(largestBill.amount))") }
        if billsPaidByReceipt > 0 { lines.append("Paid on time: \(paidOnTime) of \(billsPaidByReceipt) bills with a receipt") }
        for change in priceRises.prefix(3) {
            lines.append("\(change.vendor): \(FinishingPlan.currency(change.lastYear)) → \(FinishingPlan.currency(change.thisYear)) a bill on average (+\(Int((change.increase * 100).rounded()))%)")
        }
        if !expired.isEmpty { lines.append("Expired: " + expired.joined(separator: "; ")) }
        return lines.joined(separator: "\n") + "\n"
    }
}
