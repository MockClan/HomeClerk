// Spending: what bills and receipts add up to, month by month, by vendor or by category. Read from
// the filed documents' amounts — nothing is entered by hand, and nothing leaves the Mac.

import AppKit
import Charts
import HomeClerkKit
import SwiftUI
import UniformTypeIdentifiers

struct SpendingScreen: View {
    let model: HomeClerkModel
    @AppStorage(DefaultsKey.spendingGrouping) private var grouping = SpendingGrouping.vendor
    @AppStorage(DefaultsKey.spendingRange) private var range = SpendingRange.twelveMonths
    @State private var rows: [SpendingRow] = []
    @State private var selection: String?

    /// The groups drawn in their own color; the rest are added up as "Everything else".
    private static let shown = 7
    private static let others = "Everything else"

    var body: some View {
        Page(title: "Spending", subtitle: subtitle) {
            Picker("Group by", selection: $grouping) {
                ForEach(SpendingGrouping.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Add up by vendor or by category")
            Picker("Range", selection: $range) {
                ForEach(SpendingRange.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Range")
            Button(action: export) { Label("Export…", systemImage: "square.and.arrow.up") }
                .accessibilityLabel("Export as CSV")
                .disabled(rows.isEmpty)
                .help("Save this as a spreadsheet (CSV) for Numbers or Excel")
        } content: {
            if rows.isEmpty {
                ContentUnavailableView("No spending yet", systemImage: "chart.bar",
                                       description: Text("Bills and receipts with amounts add up here, by month, once they're filed."))
            } else {
                VSplitView {
                    chart
                        .padding()
                        .frame(minHeight: 220, idealHeight: 300)
                    totalsTable
                        .frame(minHeight: 140)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.receiptDecisionSnapshot) { load() }
        .safeAreaInset(edge: .top) {
            if model.receiptDecisionProblem != nil {
                Text("Receipt matching is suspended; receipts are counted separately. See Upcoming → Review Receipt Matches for the saved-history error.")
                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding().background(.orange.opacity(0.12))
            }
        }
        .onChange(of: grouping) { selection = nil; load() }
        .onChange(of: range) { load() }
        .onChange(of: model.state) { load() }
        .onChange(of: model.documentsChanged) { load() }
    }

    // MARK: Chart

    private var chart: some View {
        Chart(charted) { row in
            BarMark(x: .value("Month", Self.date(row.month), unit: .month), y: .value("Spent", row.amount))
                .foregroundStyle(by: .value(grouping.rawValue, row.group))
                .opacity(selection == nil || selection == row.group ? 1 : 0.25)
                .accessibilityLabel("\(row.group), \(Self.date(row.month).formatted(.dateTime.month(.wide).year()))")
                .accessibilityValue(FinishingPlan.currency(row.amount))
        }
        .chartForegroundStyleScale(domain: legendOrder, range: Array(Self.palette.prefix(legendOrder.count)))
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { if let amount = value.as(Decimal.self) { Text(Self.dollars(amount)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true)
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
        .accessibilityLabel("Spending by month, by \(grouping.rawValue.lowercased())")
    }

    // MARK: Totals

    private var totalsTable: some View {
        Table(totals, selection: $selection) {
            TableColumn(grouping.rawValue) { total in
                HStack(spacing: 6) {
                    Circle().fill(color(total.group)).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(total.group).lineLimit(1)
                }
            }
            TableColumn("Total") { Text(FinishingPlan.currency($0.amount)).monospacedDigit() }
                .width(min: 80, ideal: 100)
            TableColumn("Monthly average") { Text(FinishingPlan.currency($0.amount / Decimal(months))).monospacedDigit() }
                .width(min: 100, ideal: 120)
            TableColumn("Documents") { Text("\($0.documents)").monospacedDigit() }
                .width(min: 70, ideal: 80)
        }
        .columnsFitWithoutScrolling()
        .contextMenu(forSelectionType: String.self) { groups in
            if let group = groups.first, group != Self.others {
                Button("Show Documents") { showDocuments(group) }
            }
        } primaryAction: { groups in
            if let group = groups.first, group != Self.others { showDocuments(group) }
        }
        .safeAreaInset(edge: .bottom) {
            Text("Bills and receipts. A receipt that paid a bill isn't counted twice; statements are left out.")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.vertical, 6)
        }
    }

    private struct Total: Identifiable {
        var group: String
        var amount: Decimal
        var documents: Int
        var id: String { group }
    }

    /// Every group over the whole range, largest first.
    private var totals: [Total] {
        var byGroup: [String: Total] = [:]
        for row in rows {
            byGroup[row.group, default: Total(group: row.group, amount: 0, documents: 0)].amount += row.amount
            byGroup[row.group]!.documents += row.documents
        }
        return byGroup.values.sorted { ($1.amount, $0.group) < ($0.amount, $1.group) }
    }

    /// The largest groups, then "Everything else" — the order colors and the legend follow.
    private var legendOrder: [String] {
        let top = totals.prefix(Self.shown).map(\.group)
        return totals.count > Self.shown ? top + [Self.others] : top
    }

    /// Rows for the chart, with the smaller groups folded into "Everything else".
    private var charted: [SpendingRow] {
        let top = Set(totals.prefix(Self.shown).map(\.group))
        var folded: [String: SpendingRow] = [:]
        for row in rows where !top.contains(row.group) {
            folded[row.month, default: SpendingRow(month: row.month, group: Self.others, amount: 0, documents: 0)].amount += row.amount
        }
        return rows.filter { top.contains($0.group) } + folded.values
    }

    /// A group's color in the chart, for its dot in the table.
    private func color(_ group: String) -> Color {
        let index = legendOrder.firstIndex(of: group) ?? legendOrder.firstIndex(of: Self.others) ?? Self.shown
        return Self.palette[min(index, Self.palette.count - 1)]
    }

    /// One color per shown group, then gray for "Everything else".
    private static let palette: [Color] = [.blue, .green, .orange, .purple, .red, .teal, .pink, .gray]

    /// The rows shown, as a CSV file wherever you choose.
    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Spending by \(grouping.rawValue) - \(range.title).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SpendingRow.csv(rows, grouping: grouping).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            model.record(.problem, url.lastPathComponent, "Couldn't save the spending export: \(error.localizedDescription)", nil)
        }
    }

    /// Search, for this vendor or category's documents (double-click a row).
    private func showDocuments(_ group: String) {
        model.searchRequest = group
        model.section = .search
    }

    // MARK: Loading

    private var subtitle: String {
        guard !rows.isEmpty else { return range.title }
        let total = rows.reduce(Decimal(0)) { $0 + $1.amount }
        return "\(FinishingPlan.currency(total)) \(range.title.lowercased())"
    }

    /// Months in the range, for the monthly average.
    private var months: Int { max(1, Set(rows.map(\.month)).count) }

    private func load() {
        let (from, to) = range.days()
        rows = model.library.spending(from: from, to: to, by: grouping, decisions: model.receiptDecisionSnapshot)
        if let selected = selection, !rows.contains(where: { $0.group == selected }) { selection = nil }
    }

    private static func date(_ month: String) -> Date { FinishingPlan.localDay(month + "-01") ?? .distantPast }

    /// "$1.5K" on the axis, so long amounts don't crowd it.
    private static func dollars(_ amount: Decimal) -> String {
        let value = (amount as NSDecimalNumber).doubleValue
        guard value >= 1000 else { return value.formatted(.currency(code: "USD").precision(.fractionLength(0))) }
        return "$" + (value / 1000).formatted(.number.precision(.fractionLength(0...1))) + "K"
    }
}

/// How far back Spending looks.
enum SpendingRange: String, CaseIterable {
    case sixMonths, twelveMonths, thisYear, lastYear

    var title: String {
        switch self {
        case .sixMonths: "Last 6 Months"
        case .twelveMonths: "Last 12 Months"
        case .thisYear: "This Year"
        case .lastYear: "Last Year"
        }
    }

    /// First and last day, as yyyy-MM-dd. Rolling ranges start on the first of a month, so the
    /// first bar isn't a partial one.
    func days(today: Date = .now) -> (from: String, to: String) {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: today)
        func monthsBack(_ count: Int) -> String {
            let start = calendar.date(byAdding: .month, value: -(count - 1), to: today)!
            let c = calendar.dateComponents([.year, .month], from: start)
            return String(format: "%04d-%02d-01", c.year!, c.month!)
        }
        switch self {
        case .sixMonths: return (monthsBack(6), HomeClerkModel.day(0))
        case .twelveMonths: return (monthsBack(12), HomeClerkModel.day(0))
        case .thisYear: return ("\(year)-01-01", "\(year)-12-31")
        case .lastYear: return ("\(year - 1)-01-01", "\(year - 1)-12-31")
        }
    }
}
