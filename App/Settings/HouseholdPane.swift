// Settings ▸ Household: people, vehicles, pets, groups, and vendors HomeClerk should recognize.

import AppKit
import HomeClerkKit
import SwiftUI

/// Everyone and everything HomeClerk should recognize, for looking over and tidying. Most entries
/// arrive from corrections and Review's questions; this is where they're kept.
struct HouseholdPane: View {
    let model: HomeClerkModel
    @State private var profile = HouseholdProfile.empty
    @State private var list: HouseholdKind? = .people
    @State private var loaded = false
    /// Open rows, by list and position; a row just added opens so you can type into it.
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            Picker("List", selection: $list) {
                ForEach(HouseholdKind.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                Text("Notes").tag(HouseholdKind?.none)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top])
            .padding(.bottom, 8)

            Group {
                if let list { entries(list) } else { notes }
            }
            .frame(maxHeight: .infinity)

            Divider()
            HStack {
                Text("Kept in household.json in your HomeClerk folder, on this Mac only. Changes apply from the next scan.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.householdURL]) }
                    .controlSize(.small)
            }
            .padding(10)
        }
        .frame(height: 480)
        .onAppear {
            // Keep a row still being typed; otherwise pick up edits made to the file elsewhere
            if model.household == profile || !loaded { model.loadHousehold(force: !loaded) }
            profile = model.household
            loaded = true
        }
        .onChange(of: model.household) { if model.household != profile { profile = model.household } }
        .onChange(of: profile) { if loaded && profile != model.household { model.saveHousehold(profile) } }
    }

    @ViewBuilder
    private func entries(_ kind: HouseholdKind) -> some View {
        let count = kind == .vehicles ? profile.vehicles.count : profile.entries(kind).count
        List {
            if count == 0 {
                Text("No \(kind.title.lowercased()) yet. Add one here, or answer HomeClerk's questions in Review.")
                    .foregroundStyle(.secondary)
            }
            ForEach(0..<count, id: \.self) { i in
                if kind == .vehicles { vehicleRow(i) } else { entryRow(kind, i) }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { add(kind) } label: { Label("Add \(kind.singular.capitalized)", systemImage: "plus") }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private func entryRow(_ kind: HouseholdKind, _ i: Int) -> some View {
        let entry = Binding<ProfileEntry>(
            get: { let list = profile.entries(kind); return i < list.count ? list[i] : ProfileEntry(name: "") },
            set: { value in var list = profile.entries(kind); if i < list.count { list[i] = value; profile.setEntries(kind, list) } })
        return DisclosureGroup(isExpanded: isExpanded(kind, i)) {
            Form {
                TextField("Name", text: readable(entry.name), prompt: Text("Name"))
                TextField("Also appears as", text: commaList(entry.aliases), prompt: Text("Separate with commas"))
                learned(kind, entry.wrappedValue.aliases)
                TextField("Notes", text: entry.notes, prompt: Text("Anything that helps file it"), axis: .vertical)
                Button("Remove \(kind.singular.capitalized)", role: .destructive) {
                    var list = profile.entries(kind); list.remove(at: i); profile.setEntries(kind, list)
                    expanded.remove("\(kind.rawValue)#\(i)")
                }
            }
        } label: {
            label(entry.wrappedValue.name, entry.wrappedValue.aliases)
        }
    }

    private func vehicleRow(_ i: Int) -> some View {
        let vehicle = Binding<VehicleEntry>(
            get: { i < profile.vehicles.count ? profile.vehicles[i] : VehicleEntry(name: "") },
            set: { if i < profile.vehicles.count { profile.vehicles[i] = $0 } })
        return DisclosureGroup(isExpanded: isExpanded(.vehicles, i)) {
            Form {
                TextField("Name", text: readable(vehicle.name), prompt: Text("2021 Toyota RAV4"))
                TextField("Also appears as", text: commaList(vehicle.aliases), prompt: Text("Separate with commas"))
                learned(.vehicles, vehicle.wrappedValue.aliases)
                TextField("VIN", text: vehicle.vin)
                TextField("Plates", text: commaList(vehicle.plates), prompt: Text("Separate with commas"))
                TextField("Notes", text: vehicle.notes, axis: .vertical)
                Button("Remove Vehicle", role: .destructive) {
                    profile.vehicles.remove(at: i)
                    expanded.remove("vehicles#\(i)")
                }
            }
        } label: {
            label(vehicle.wrappedValue.name, vehicle.wrappedValue.aliases)
        }
    }

    private func label(_ name: String, _ aliases: [String]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name.isEmpty ? "New" : FinishingPlan.readable(name))
            if !aliases.isEmpty {
                Text("Also: " + aliases.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// Which aliases came from corrections, and when — so a wrong one is easy to spot and remove.
    @ViewBuilder
    private func learned(_ kind: HouseholdKind, _ aliases: [String]) -> some View {
        let records = aliases.compactMap { profile.learnedRecord($0, kind: kind) }
        if !records.isEmpty {
            Text(records.map { "“\($0.alias)” learned from a correction\(Self.day($0.date))" }.joined(separator: "\n"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private static func day(_ value: String) -> String {
        FinishingPlan.localDay(value).map { " on " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Facts about how your household files things, one per line. HomeClerk reads them before each document.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { profile.notes.joined(separator: "\n") },
                                     set: { profile.notes = $0.components(separatedBy: "\n") }))
                .font(.body)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            Text("Blank lines are dropped when HomeClerk reads them.").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding()
    }

    private func add(_ kind: HouseholdKind) {
        let index: Int
        if kind == .vehicles {
            index = profile.vehicles.count
            profile.vehicles.append(VehicleEntry(name: ""))
        } else {
            index = profile.entries(kind).count
            profile.setEntries(kind, profile.entries(kind) + [ProfileEntry(name: "")])
        }
        expanded.insert("\(kind.rawValue)#\(index)")
    }

    private func isExpanded(_ kind: HouseholdKind, _ i: Int) -> Binding<Bool> {
        let key = "\(kind.rawValue)#\(i)"
        return Binding(get: { expanded.contains(key) },
                       set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
    }

    private func readable(_ binding: Binding<String>) -> Binding<String> {
        Binding(get: { FinishingPlan.readable(binding.wrappedValue) },
                set: { binding.wrappedValue = $0.replacingOccurrences(of: " ", with: "_") })
    }

    private func commaList(_ binding: Binding<[String]>) -> Binding<String> {
        Binding(get: { binding.wrappedValue.joined(separator: ", ") },
                set: { binding.wrappedValue = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })
    }
}
