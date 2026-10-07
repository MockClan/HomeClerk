// Upcoming: bills due and documents expiring, with paid bills checked off.

import AppKit
import HomeClerkKit
import PDFKit
import QuickLook
import SwiftUI

struct UpcomingScreen: View {
    let model: HomeClerkModel
    @State private var days = 60
    @AppStorage(DefaultsKey.upcomingShowsPaid) private var showPaid = false
    @State private var items: [UpcomingItem] = []
    @State private var selection: UpcomingItem.ID?
    @State private var order = [KeyPathComparator(\UpcomingItem.date)]
    @State private var preview: URL?
    @State private var showReceiptMatches = false
    @Environment(\.undoManager) private var undoManager

    private var overdue: Int { items.filter(isOverdue).count }
    private var receiptReviewTitle: String {
        let count = model.receiptMatchIndex.proposals.filter { $0.status == .suggested && $0.canConfirm }.count
        return count == 0 ? "Review Receipt Matches" : "Review Receipt Matches (\(count))"
    }

    var body: some View {
        Page(title: "Upcoming", subtitle: subtitle) {
            Picker("Range", selection: $days) {
                Text("30 days").tag(30)
                Text("60 days").tag(60)
                Text("90 days").tag(90)
                Text("1 year").tag(365)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button {
                if let bill = selectedBill { setPaid(!(bill.payment?.isPaid ?? false), bill) }
            } label: {
                Label(selectedBill?.payment?.isPaid == true ? "Mark as Not Paid" : "Mark as Paid", systemImage: "checkmark.square")
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(selectedBill == nil)
            .help(selectedBill?.payment?.isPaid == true ? "Mark the selected bill not paid (⇧⌘P)" : "Mark the selected bill paid (⇧⌘P)")
            Toggle(isOn: $showPaid) { Label("Show Paid", systemImage: "checkmark.circle") }
                .toggleStyle(.button)
                .accessibilityLabel("Show Paid")
                .help(showPaid ? "Hide bills that are paid" : "Show bills that are paid too")
        } content: {
            if items.isEmpty {
                ContentUnavailableView("Nothing due or expiring", systemImage: "calendar",
                                       description: Text("Bills due and documents expiring in the next \(days) days show up here. A bill is marked paid when you file its receipt, or check it off here."))
            } else {
                Table(items, selection: $selection, sortOrder: $order) {
                    TableColumn("Paid") { item in
                        if let payment = item.payment {
                            Toggle("Paid", isOn: Binding(get: { payment.isPaid }, set: { setPaid($0, item) }))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .help(paidHelp(payment))
                        }
                    }
                    .width(36)
                    TableColumn("When", value: \.date) { item in
                        Text(when(item.date)).monospacedDigit()
                            .foregroundStyle(isOverdue(item) ? .red : item.payment?.isPaid == true ? .secondary
                                             : soon(item.date) ? .orange : .primary)
                    }
                    .width(min: 90, ideal: 110, max: 140)
                    TableColumn("", value: \.kind.rawValue) { item in
                        if isOverdue(item) {
                            Label("Overdue", systemImage: "exclamationmark.circle").foregroundStyle(.red)
                        } else {
                            Label(item.kind.rawValue, systemImage: item.kind == .due ? "creditcard" : "hourglass")
                                .foregroundStyle(item.kind == .due ? Color.blue : Color.orange)
                        }
                    }
                    .width(min: 92, ideal: 100, max: 120)
                    TableColumn("What", value: \.title) { item in
                        HStack(spacing: 4) {
                            Text(item.title).lineLimit(1)
                                .foregroundStyle(item.payment?.isPaid == true ? .secondary : .primary)
                            if let usual = item.usual {
                                Image(systemName: "arrow.up.circle.fill").foregroundStyle(.orange)
                                    .help("Higher than usual — this vendor's bills are usually about \(FinishingPlan.currency(usual))")
                                    .accessibilityLabel("Higher than usual")
                            }
                        }
                        .contextMenu { menu(item) }
                        .onDrag { FileDrag.provider(item.path) }
                    }
                    TableColumn("Document") { item in
                        Text((item.path as NSString).lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .columnsFitWithoutScrolling()
                .contextMenu(forSelectionType: UpcomingItem.ID.self) { ids in
                    if let item = items.first(where: { ids.contains($0.id) }) { menu(item) }
                } primaryAction: { ids in
                    for item in items where ids.contains(item.id) { NSWorkspace.shared.open(URL(fileURLWithPath: item.path)) }
                }
                .onChange(of: order) { items.sort(using: order) }
                .quickLookOnSpace(selected: items.first { $0.id == selection }.map { URL(fileURLWithPath: $0.path) },
                                  all: items.map { URL(fileURLWithPath: $0.path) }, preview: $preview)
            }
        }
        .onAppear(perform: load)
        .onChange(of: days) { load() }
        .onChange(of: showPaid) { load() }
        .onChange(of: model.state) { load() }   // settings changed, or the first launch finished starting
        .onChange(of: model.documentsChanged) { load() }   // a receipt filed can pay a bill
        .onChange(of: model.receiptDecisionSnapshot) { load() }
        .safeAreaInset(edge: .top) {
            if model.receiptDecisionProblem != nil {
                HStack {
                    Text("Receipt matching is suspended. Hand paid marks still apply.").font(.callout)
                    Spacer()
                    Button("Review Matches") { showReceiptMatches = true }
                }.padding().background(.orange.opacity(0.12))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(receiptReviewTitle, systemImage: "doc.on.doc") { showReceiptMatches = true }
            }
        }
        .sheet(isPresented: $showReceiptMatches) { ReceiptMatchesView(model: model) }
    }

    private var subtitle: String {
        if items.isEmpty { return "Nothing due" }
        let count = items.count == 1 ? "1 item" : "\(items.count) items"
        return overdue == 0 ? count : "\(count), \(overdue) overdue"
    }

    @ViewBuilder private func menu(_ item: UpcomingItem) -> some View {
        if let payment = item.payment {
            if payment.isPaid {
                Button("Mark as Not Paid") { setPaid(false, item) }
            } else {
                Button("Mark as Paid") { setPaid(true, item) }
            }
            if case .receipt(let receipt) = payment {
                Button("Show Receipt") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: receipt)]) }
            }
            Divider()
        }
        FileMenu(path: item.path, preview: $preview)
    }

    /// The selected row, when it's a bill.
    private var selectedBill: UpcomingItem? { items.first { $0.id == selection && $0.payment != nil } }

    /// Checking marks it paid. Unchecking goes back to matching receipts — or, if a receipt still
    /// pays it, says it isn't paid regardless. ⌘Z puts back the mark it had.
    private func setPaid(_ paid: Bool, _ item: UpcomingItem) {
        let before = model.paidMark(path: item.path)
        undoManager?.registerUndo(withTarget: model) { model in
            MainActor.assumeIsolated {
                model.setPaid(before, path: item.path)
            }
        }
        undoManager?.setActionName(paid ? "Mark as Paid" : "Mark as Not Paid")
        if paid {
            model.setPaid(true, path: item.path)
        } else {
            model.setPaid(nil, path: item.path)
            if model.upcoming(days: days, includePaid: true).first(where: { $0.id == item.id })?.payment?.isPaid == true {
                model.setPaid(false, path: item.path)
            }
        }
        load()
    }

    private func paidHelp(_ payment: BillPayment) -> String {
        switch payment {
        case .unpaid: "Not paid — check when you've paid it"
        case .markedPaid: "Marked paid"
        case .receipt(let path): "Paid — matched the receipt \((path as NSString).lastPathComponent)"
        }
    }

    private func load() { items = model.upcoming(days: days, includePaid: showPaid).sorted(using: order) }

    private func isOverdue(_ item: UpcomingItem) -> Bool {
        item.kind == .due && item.payment?.isPaid != true && item.date < DocumentProcessor.localToday()
    }

    private func soon(_ day: String) -> Bool {
        guard let date = FinishingPlan.localDay(day) else { return false }
        return date.timeIntervalSinceNow < 7 * 86_400
    }

    private func when(_ day: String) -> String {
        guard let date = FinishingPlan.localDay(day) else { return day }
        let away = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: date).day ?? 0
        switch away {
        case -1: return "Yesterday"
        case -7 ... -2: return "\(-away) days ago"
        case 0: return "Today"
        case 1: return "Tomorrow"
        case 2...7: return "In \(away) days"
        default: return date.formatted(.dateTime.month(.abbreviated).day().year())
        }
    }
}

private struct ReceiptMatchesView: View {
    let model: HomeClerkModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @State private var selection: String?
    @State private var onlyNeedsReview = false
    @State private var message: String?
    @State private var showUnavailable = false
    private var pairs: [ReceiptMatchProposal] {
        model.receiptMatchIndex.proposals.filter { !onlyNeedsReview || ($0.status == .suggested && $0.canConfirm) }
            .sorted { rank($0.status) == rank($1.status) ? $0.bill.path < $1.bill.path : rank($0.status) < rank($1.status) }
    }
    private var selected: ReceiptMatchProposal? { pairs.first { $0.id == selection } }
    private var busy: Bool {
        selected.map { model.documentIsBusy($0.bill.path) || model.documentIsBusy($0.receipt.path) } ?? false
    }
    private func rank(_ status: ReceiptMatchProposal.Status) -> Int {
        switch status { case .suggested: 0; case .automatic: 1; case .confirmed: 2; case .rejected: 3 }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Receipt Matches").font(.title2.weight(.semibold))
                Spacer()
                Toggle("Needs Review Only", isOn: $onlyNeedsReview).toggleStyle(.checkbox)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            if let problem = model.receiptDecisionProblem { Text(problem).font(.callout).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal) }
            Divider()
            HStack(spacing: 0) {
                List(pairs, selection: $selection) { pair in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pair.bill.facets.vendor.isEmpty ? "Unknown vendor" : FinishingPlan.readable(pair.bill.facets.vendor))
                        Text("Due \(pair.bill.facets.dueDate) · \(pair.status.rawValue)").font(.caption).foregroundStyle(.secondary)
                        Text((pair.receipt.path as NSString).lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                    }.tag(pair.id)
                }.frame(width: 250)
                Divider()
                if let pair = selected { comparison(pair) }
                else {
                    ContentUnavailableView("No receipt pairs to review", systemImage: "doc.on.doc",
                        description: Text("Proposals need the same vendor and amount within the payment date window. Subject differences require your confirmation. Saved decisions remain available when both documents return to the Library."))
                        .frame(maxWidth: .infinity)
                }
            }
            Divider()
            if !model.unavailableReceiptDecisions.isEmpty {
                HStack {
                    Text("\(model.unavailableReceiptDecisions.count) saved decisions have unavailable documents.").font(.callout)
                    Spacer()
                    Button("Review Saved Decisions") { showUnavailable = true }
                }.padding(.horizontal).padding(.vertical, 8)
                Divider()
            }
            Text("Hand paid/not-paid marks take priority. Confirm links one bill to one receipt; Reject excludes this pair. Reset returns it to automatic matching.")
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal).padding(.vertical, 8)
            if let message { Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal).padding(.bottom, 8) }
        }
        .frame(minWidth: 1000, minHeight: 650)
        .onAppear { model.refreshReceiptDecisions(); chooseFirst() }
        .onChange(of: onlyNeedsReview) { chooseFirst() }
        .onChange(of: model.documentsChanged) { chooseFirst() }
        .onChange(of: selection) { message = nil }
        .sheet(isPresented: $showUnavailable) { UnavailableReceiptDecisionsView(model: model) }
    }
    private func chooseFirst() { if !pairs.contains(where: { $0.id == selection }) { selection = pairs.first?.id } }
    private func comparison(_ pair: ReceiptMatchProposal) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                document("Bill", pair.bill)
                Divider()
                document("Receipt", pair.receipt)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(pair.status.rawValue) · \(pair.active ? "Linked for receipt matching" : "Not linked for payment")").font(.headline)
                    if let mark = model.paidMark(path: pair.bill.path) {
                        Text("This bill is marked \(mark ? "paid" : "not paid") by hand. That mark takes priority; change it in Upcoming.").font(.callout)
                    }
                    ForEach(pair.reasons, id: \.self) { Text($0).font(.callout) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }.frame(maxHeight: 150)
            HStack {
                if pair.status == .confirmed || pair.status == .rejected {
                    Button("Reset Decision") { decide(nil, pair) }
                        .disabled(busy || !model.receiptDecisionSnapshot.available)
                }
                Spacer()
                Button("Reject Match") { decide(false, pair) }
                    .disabled(busy || !model.receiptDecisionSnapshot.available || pair.status == .rejected)
                Button("Confirm Match") { decide(true, pair) }
                    .buttonStyle(.borderedProminent).disabled(busy || !pair.canConfirm || pair.status == .confirmed)
            }.padding()
        }.frame(maxWidth: .infinity)
    }
    private func document(_ label: String, _ entry: DocumentIndex.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.headline)
            Text((entry.path as NSString).lastPathComponent).font(.caption).lineLimit(2).truncationMode(.middle)
            Text("\(entry.facets.documentType) · \(entry.facets.amount.map(FinishingPlan.currency) ?? "No amount") · Dated \(entry.facets.documentDate.isEmpty ? "unspecified" : entry.facets.documentDate)")
                .font(.callout)
            Text([entry.facets.person, entry.facets.vehicle, entry.facets.pet].filter { !$0.isEmpty }.map(FinishingPlan.readable).joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            PDFPreview(url: URL(fileURLWithPath: entry.path)).frame(minHeight: 180, maxHeight: .infinity)
            Button("Open PDF") { NSWorkspace.shared.open(URL(fileURLWithPath: entry.path)) }
        }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func decide(_ value: Bool?, _ pair: ReceiptMatchProposal) {
        message = model.decideReceipt(value, proposal: pair, undoManager: undoManager)
    }
}

private struct UnavailableReceiptDecisionsView: View {
    let model: HomeClerkModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @State private var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Saved Receipt Decisions").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("One or both documents are unavailable or cannot be identified uniquely. Confirmations stay reserved until you reset them. Last recorded names may have changed; resetting allows automatic matching again and supports Undo.")
                .font(.callout).foregroundStyle(.secondary)
            List(model.unavailableReceiptDecisions) { record in
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.confirmed ? "Confirmed" : "Rejected").font(.headline)
                        Text("Bill: \(record.billName ?? "Unavailable document")")
                        Text("Receipt: \(record.receiptName ?? "Unavailable document")")
                    }.font(.callout)
                    Spacer()
                    Button("Reset Decision") { problem = model.resetUnavailableReceiptDecision(record, undoManager: undoManager) }
                }.padding(.vertical, 5)
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }.padding().frame(minWidth: 650, minHeight: 400)
    }
}
