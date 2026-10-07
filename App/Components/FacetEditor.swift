// The correction form Review and Filed share: a document's details, with fields that check dates
// and amounts as you type.

import AppKit
import HomeClerkKit
import SwiftUI

/// The details HomeClerk read, editable, with where they'd file the document. Review and Filed
/// both use it, so correcting works the same before and after filing.
struct FacetEditor: View {
    let model: HomeClerkModel
    @Binding var facets: DocumentFacets
    /// A folder you chose; empty to let the rules decide.
    @Binding var folder: String

    var body: some View {
        let taxonomy = model.taxonomy
        SwiftUI.Section("Details") {
            NameField(label: "Vendor", value: $facets.vendor, names: model.household.names(.vendors), symbol: "building.2")
            TextField("What", text: readable($facets.description), prompt: Text("Electric Bill"))
            Picker("Type", selection: $facets.documentType) {
                ForEach(choices(taxonomy?.documentTypes.map(\.name) ?? [], facets.documentType), id: \.self) { Text(Self.readable($0)).tag($0) }
            }
            Picker("Area", selection: $facets.area) {
                ForEach(choices(taxonomy?.areas.map(\.name) ?? [], facets.area), id: \.self) { Text(Self.readable($0)).tag($0) }
            }
            DayField(label: "Date", value: $facets.documentDate)
            AmountField(value: $facets.amount)
        }
        SwiftUI.Section("Who and what it's about") {
            NameField(label: "Person", value: $facets.person,
                      names: model.household.names(.people) + model.household.names(.groups))
            NameField(label: "Vehicle", value: $facets.vehicle, names: model.household.names(.vehicles), symbol: "car")
            NameField(label: "Pet", value: $facets.pet, names: model.household.names(.pets), symbol: "pawprint")
            TextField("Tags", text: Binding(get: { facets.tags.joined(separator: ", ") },
                                            set: { facets.tags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }),
                      prompt: Text("insurance, renewal"))
            DayField(label: "Due", value: $facets.dueDate)
            DayField(label: "Expires", value: $facets.expiresOn)
        }
        if let actions = model.reviewActions {
            let (target, name) = actions.destination(facets, folder: folder)
            let ruled = actions.destination(facets).folder
            SwiftUI.Section("Will be filed as") {
                LabeledContent("Folder") {
                    Menu(target) {
                        Button("\(ruled) (from the rules)") { folder = "" }
                        Divider()
                        ForEach(actions.folders(), id: \.self) { choice in Button(choice) { folder = choice } }
                    }
                    .fixedSize()
                }
                Text(name).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    /// The taxonomy's choices, plus the current value if the model used one outside them.
    private func choices(_ list: [String], _ current: String) -> [String] {
        list.contains(current) || current.isEmpty ? list : [current] + list
    }

    static func readable(_ value: String) -> String { FinishingPlan.readable(value) }

    /// Every date is empty or a real yyyy-MM-dd day — anything else would end up in a file name.
    static func datesValid(_ f: DocumentFacets) -> Bool {
        [f.documentDate, f.dueDate, f.expiresOn].allSatisfy { $0.isEmpty || FinishingPlan.day($0) != nil }
    }

    /// Shown with spaces, stored with underscores, as file names use them.
    private func readable(_ binding: Binding<String>) -> Binding<String> {
        Binding(get: { Self.readable(binding.wrappedValue) },
                set: { binding.wrappedValue = $0.replacingOccurrences(of: " ", with: "_") })
    }
}

/// A name you can type or pick from the household's list.
struct NameField: View {
    let label: String
    @Binding var value: String
    let names: [String]
    var symbol = "person.crop.circle"

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField(label, text: Binding(get: { FinishingPlan.readable(value) },
                                               set: { value = $0.replacingOccurrences(of: " ", with: "_") }))
                    .labelsHidden()
                if !names.isEmpty {
                    Menu {
                        ForEach(names, id: \.self) { name in Button(FinishingPlan.readable(name)) { value = name } }
                        Divider()
                        Button("None") { value = "" }
                    } label: { Image(systemName: symbol).accessibilityLabel("Choose \(label) from your household") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Choose from your household")
                }
            }
        }
    }
}

/// A yyyy-MM-dd date, flagged when it isn't one.
struct DayField: View {
    let label: String
    @Binding var value: String

    var body: some View {
        LabeledContent(label) {
            TextField(label, text: $value, prompt: Text("yyyy-mm-dd"))
                .labelsHidden()
                .monospacedDigit()
                .foregroundStyle(value.isEmpty || FinishingPlan.day(value) != nil ? Color.primary : Color.red)
        }
    }
}

struct AmountField: View {
    @Binding var value: Decimal?
    @State private var text = ""

    /// 42 → "42.00" (or "42,00" where a comma is the decimal mark), without grouping.
    static func format(_ value: Decimal?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(2)).grouping(.never)) } ?? ""
    }

    /// Reads an amount as typed here: "$1,234.50" in the US, "1.234,50 €" in much of Europe.
    static func parse(_ text: String) -> Decimal? {
        let locale = Locale.current
        let grouping = locale.groupingSeparator ?? ",", decimal = locale.decimalSeparator ?? "."
        let digits = text.filter { $0.isNumber || String($0) == decimal || String($0) == grouping || $0 == "-" }
            .replacingOccurrences(of: grouping, with: "")
        return Decimal(string: digits, locale: locale)
    }

    var body: some View {
        TextField("Amount", text: $text, prompt: Text("0.00"))
            .monospacedDigit()
            .onAppear { text = Self.format(value) }
            .onChange(of: value) { if Decimal(string: text) != value { text = Self.format(value) } }
            .onChange(of: text) {
                let cleaned = text.trimmingCharacters(in: .whitespaces)
                value = cleaned.isEmpty ? nil : Self.parse(cleaned) ?? value
            }
    }
}
