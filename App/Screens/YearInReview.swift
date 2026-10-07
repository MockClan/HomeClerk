// File ▸ Year in Review: a year of paperwork at a glance — filed, spent, paid on time, what got
// dearer, and what expired — with Copy Summary for keeping or sharing it.

import AppKit
import HomeClerkKit
import SwiftUI

struct YearInReviewSheet: View {
    let model: HomeClerkModel
    @Environment(\.dismiss) private var dismiss
    @State private var year = Calendar.current.component(.year, from: .now)
    @State private var copied = false

    private var years: [Int] { YearInReview.years(in: model.library) }
    private var review: YearInReview { YearInReview(year: year, library: model.library, decisions: model.receiptDecisionSnapshot) }

    var body: some View {
        let review = review
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Year in Review").font(.title2.weight(.semibold))
                Spacer()
                Picker("Year", selection: $year) {
                    ForEach(years.isEmpty ? [year] : years, id: \.self) { Text(String($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if review.documents == 0 {
                ContentUnavailableView("Nothing filed for \(String(year))", systemImage: "calendar",
                                       description: Text("Documents dated in a year show up here once they're filed."))
                    .frame(minHeight: 200)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    row("Filed", "\(review.documents) documents"
                        + (review.byArea.isEmpty ? "" : " — " + review.byArea.prefix(4).map { "\($0.count) \($0.name)" }.joined(separator: ", ")))
                    if let month = review.busiestMonth { row("Busiest month", "\(monthName(month.name)) (\(month.count))") }
                    row("Spent", FinishingPlan.currency(review.spent))
                    if !review.topVendors.isEmpty {
                        row("Top vendors", review.topVendors.map { "\($0.name) \(FinishingPlan.currency($0.amount))" }.joined(separator: "\n"))
                    }
                    if let bill = review.largestBill { row("Largest bill", "\(bill.name) \(FinishingPlan.currency(bill.amount))") }
                    if review.billsPaidByReceipt > 0 {
                        row("Paid on time", "\(review.paidOnTime) of \(review.billsPaidByReceipt) bills with a receipt")
                    }
                    if !review.priceRises.isEmpty {
                        row("Got dearer", review.priceRises.prefix(3).map {
                            "\($0.vendor): \(FinishingPlan.currency($0.lastYear)) → \(FinishingPlan.currency($0.thisYear)) (+\(Int(($0.increase * 100).rounded()))%)"
                        }.joined(separator: "\n"))
                    }
                    if !review.expired.isEmpty { row("Expired", review.expired.joined(separator: "\n")) }
                }
                Text("Spending counts bills and receipts that didn't pay a bill; statements are left out. \"Got dearer\" compares a vendor's average bill with the year before.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(copied ? "Copied" : "Copy Summary") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(review.text, forType: .string)
                    copied = true
                }
                .disabled(review.documents == 0)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { if let latest = years.first, !years.contains(year) { year = latest } }
        .onChange(of: year) { copied = false }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "2030-03" → "March".
    private func monthName(_ month: String) -> String {
        FinishingPlan.localDay(month + "-01").map { $0.formatted(.dateTime.month(.wide)) } ?? month
    }
}
