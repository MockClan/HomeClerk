// Usage: what paid AI calls cost, by month and model.

import AppKit
import HomeClerkKit
import PDFKit
import QuickLook
import SwiftUI

struct UsageScreen: View {
    let model: HomeClerkModel
    @State private var summary = UsageSummary([])

    private var usageSubtitle: String {
        guard !summary.rows.isEmpty else { return "No paid calls yet" }
        var total = "\(summary.total.formatted(.currency(code: "USD"))) estimated in all"
        if let average = summary.averageCost { total += " · about \(UsageSummary.perScan(average)) a scan" }
        let budget = model.claudeBudget
        guard budget.limit > 0 else { return total }
        return total + " · \(FinishingPlan.currency(budget.spent)) of \(FinishingPlan.currency(budget.limit)) this month"
    }

    var body: some View {
        Page(title: "Usage", subtitle: usageSubtitle) {
            if summary.rows.isEmpty {
                ContentUnavailableView("No paid API calls yet", systemImage: "dollarsign.circle",
                                       description: Text("Claude calls are recorded here with their estimated cost. Local models are free."))
            } else {
                Table(summary.rows) {
                    TableColumn("Month", value: \.month).width(min: 70, ideal: 80)
                    TableColumn("Model", value: \.model)
                    TableColumn("Calls") { Text("\($0.calls)").monospacedDigit() }.width(min: 50, ideal: 60)
                    TableColumn("Tokens in / out") { Text("\($0.inputTokens.formatted()) / \($0.outputTokens.formatted())").monospacedDigit() }
                    TableColumn("Est. cost") { Text($0.cost.map { $0.formatted(.currency(code: "USD")) } ?? "?").monospacedDigit() }
                        .width(min: 70, ideal: 80)
                    TableColumn("Per scan") { Text($0.averageCost.map(UsageSummary.perScan) ?? "?").monospacedDigit() }
                        .width(min: 60, ideal: 70)
                }
                .columnsFitWithoutScrolling()
            }
        }
        .onAppear { summary = model.usage() }
        .onChange(of: model.state) { summary = model.usage() }   // settings changed, or starting up finished
        .onChange(of: model.filed) { summary = model.usage() }
    }
}
