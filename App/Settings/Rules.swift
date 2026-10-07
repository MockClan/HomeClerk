// Settings ▸ Rules: the folders documents go to, how long they're kept, and the suggested tags —
// your own copy of taxonomy.json in the HomeClerk folder — and applying changed rules to documents
// already filed.

import AppKit
import HomeClerkKit
import SwiftUI

extension HomeClerkModel {
    var builtInTaxonomyURL: URL? { Bundle.main.url(forResource: "taxonomy", withExtension: "json") }
    var customTaxonomyURL: URL {
        (currentSettings ?? SettingsStore.app.load()).basePath.appendingPathComponent(TaxonomyConfig.fileName)
    }

    /// Saves your rules (an invalid set is refused) and restarts watching so new scans use them.
    func saveRules(_ config: TaxonomyConfig) throws {
        try config.save(to: customTaxonomyURL)
        scheduleRestart()
    }

    /// Back to the built-in rules: your copy goes to the Trash, so it can be put back.
    func useBuiltInRules() throws {
        if FileManager.default.fileExists(atPath: customTaxonomyURL.path) {
            try FileManager.default.trashItem(at: customTaxonomyURL, resultingItemURL: nil)
        }
        scheduleRestart()
    }
}

/// In Activity when your taxonomy.json can't be used.
struct TaxonomyProblemBanner: View {
    let problem: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your rules have a problem, so the built-in ones are in use").font(.callout.weight(.medium))
                Text(problem).font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
            }
            Spacer()
            SettingsLink { Text("Open Rules…") }
        }
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct RulesPane: View {
    let model: HomeClerkModel
    enum Part: String { case folders, keep, tags }
    @State private var part = Part.folders
    @State private var config: TaxonomyConfig?
    @State private var problems: [String] = []
    @State private var expanded: Int?
    @State private var showRefile = false
    @State private var confirmRevert = false
    @State private var saveTask: Task<Void, Never>?
    @AppStorage(DefaultsKey.rulesByName) private var byName = false
    /// Rows in display order, by index. Sorted when the list is shown or changes length, not as you
    /// type, so a row being renamed doesn't jump away.
    @State private var order: [Int] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("Show", selection: $part) {
                Text("Folders").tag(Part.folders)
                Text("Keep Periods").tag(Part.keep)
                Text("Tags").tag(Part.tags)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.bottom, 8)

            if config != nil {
                switch part {
                case .folders: folders
                case .keep: keepPeriods
                case .tags: tags
                }
            }

            if !problems.isEmpty {
                Text("Not saved: " + problems.joined(separator: "; "))
                    .font(.caption).foregroundStyle(.red).padding(.horizontal).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Apply to Filed Documents…") { showRefile = true }
                    .help("Moves documents already filed to where these rules put them")
                Spacer()
            }
            .padding(10)
        }
        .frame(height: 520)
        .onAppear(perform: load)
        .onChange(of: part) { resort() }
        .onChange(of: byName) { expanded = nil; resort() }
        .onChange(of: rowCount) { resort() }
        .sheet(isPresented: $showRefile) { if let config { RefileSheet(model: model, taxonomy: config) } }
        .confirmationDialog("Go back to the built-in rules?", isPresented: $confirmRevert) {
            Button("Use Built-in Rules", role: .destructive) {
                // An edit still waiting to save would write taxonomy.json right back
                saveTask?.cancel()
                do {
                    try model.useBuiltInRules()
                    load()
                } catch {
                    problems = ["Couldn't move your taxonomy.json to the Trash: \(error.localizedDescription)"]
                }
            }
        } message: {
            Text("Your taxonomy.json goes to the Trash. Documents already filed stay where they are.")
        }
    }

    private var header: some View {
        let custom = FileManager.default.fileExists(atPath: model.customTaxonomyURL.path)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(custom ? "Your rules" : "The built-in rules").font(.headline)
                Text(custom ? (model.customTaxonomyURL.path as NSString).abbreviatingWithTildeInPath
                            : "Edit them here; your copy is saved as taxonomy.json in the HomeClerk folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if custom {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.customTaxonomyURL]) }
                Button("Use Built-in…") { confirmRevert = true }
            }
        }
        .controlSize(.small)
        .padding()
    }

    private func load() {
        guard let builtIn = model.builtInTaxonomyURL else { return }
        config = try? TaxonomyConfig.loadEffective(custom: model.customTaxonomyURL, builtIn: builtIn).config
        problems = []
        resort()
    }

    // MARK: Order

    private var rowCount: Int {
        switch part {
        case .folders: config?.rules.count ?? 0
        case .keep: config?.retention.count ?? 0
        case .tags: config?.suggestedTags.count ?? 0
        }
    }

    /// Folder rules and keep periods by priority (the order they're checked) unless sorted by name;
    /// tags always alphabetically, since their order doesn't matter.
    private func resort() {
        guard let config else { order = []; return }
        let names: [String]
        switch part {
        case .folders: names = byName ? config.rules.map(\.folder) : []
        case .keep: names = byName ? config.retention.map { ConditionEditor.summary($0.condition) } : []
        case .tags: names = config.suggestedTags.map(\.tag)
        }
        order = names.isEmpty ? Array(0..<rowCount)
            : names.indices.sorted {
                let c = names[$0].localizedStandardCompare(names[$1])
                return c == .orderedSame ? $0 < $1 : c == .orderedAscending
            }
    }

    /// `order`, trusting it only while it matches the list (it's refreshed right after a change).
    private func rows(_ count: Int) -> [Int] {
        order.count == count && order.allSatisfy { $0 < count } ? order : Array(0..<count)
    }

    /// "Checked 3rd · " when sorted by name, so the order that matters stays visible.
    private func priority(_ i: Int) -> String {
        guard byName else { return "" }
        let ordinal = NumberFormatter()
        ordinal.numberStyle = .ordinal
        return "Checked \(ordinal.string(from: NSNumber(value: i + 1)) ?? "\(i + 1)") · "
    }

    private var sortPicker: some View {
        Picker("Sort", selection: $byName) {
            Text("By Priority").tag(false)
            Text("By Name").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// Saves a moment after the last change, so typing a folder name doesn't restart HomeClerk per key.
    private func changed(_ update: (inout TaxonomyConfig) -> Void) {
        guard var current = config else { return }
        update(&current)
        config = current
        problems = current.validate()
        saveTask?.cancel()
        guard problems.isEmpty else { return }
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            do { try model.saveRules(current) } catch { problems = ["\(error)"] }
        }
    }

    private func binding<T>(_ get: @escaping (TaxonomyConfig) -> T, _ set: @escaping (inout TaxonomyConfig, T) -> Void) -> Binding<T> {
        Binding(get: { config.map(get)! }, set: { value in changed { set(&$0, value) } })
    }

    // MARK: Folders

    private var folders: some View {
        let rules = config?.rules ?? []
        return List {
            HStack(alignment: .firstTextBaseline) {
                Text(byName ? "The first rule that matches decides the folder; each shows where it's checked. Sort by priority to reorder."
                            : "Checked top to bottom; the first rule that matches decides the folder. Drag to reorder.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                sortPicker
            }
            ForEach(rows(rules.count), id: \.self) { i in
                DisclosureGroup(isExpanded: Binding(get: { expanded == i }, set: { expanded = $0 ? i : nil })) {
                    Form {
                        TextField("Folder", text: binding({ $0.rules[i].folder }, { $0.rules[i].folder = $1 }))
                        ConditionEditor(condition: binding({ $0.rules[i].condition }, { $0.rules[i].condition = $1 }),
                                        taxonomy: config!)
                        Button("Remove Rule", role: .destructive) { changed { $0.rules.remove(at: i) }; expanded = nil }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rules[i].folder.isEmpty ? "New folder" : rules[i].folder)
                        Text(priority(i) + ConditionEditor.summary(rules[i].condition)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .onMove(perform: byName ? nil : { from, to in changed { $0.rules.move(fromOffsets: from, toOffset: to) }; expanded = nil })
            Button { changed { $0.rules.insert(FilingRule(folder: "New Folder", condition: FacetCondition(tagsAny: ["new-tag"])), at: 0) }; expanded = 0 } label: {
                Label("Add Folder Rule", systemImage: "plus")
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: Keep periods

    private var keepPeriods: some View {
        let rules = config?.retention ?? []
        return List {
            HStack(alignment: .firstTextBaseline) {
                Text("How long each kind of document is worth keeping; the first match applies. Tidy Up suggests what's past its time — nothing is deleted on its own.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                sortPicker
            }
            ForEach(rows(rules.count), id: \.self) { i in
                DisclosureGroup(isExpanded: Binding(get: { expanded == i }, set: { expanded = $0 ? i : nil })) {
                    Form {
                        ConditionEditor(condition: binding({ $0.retention[i].condition }, { $0.retention[i].condition = $1 }),
                                        taxonomy: config!)
                        Toggle("Keep indefinitely", isOn: binding({ $0.retention[i].keepYears == nil },
                                                                   { $0.retention[i].keepYears = $1 ? nil : 1 }))
                        if let years = rules[i].keepYears {
                            Stepper("Keep \(years) year\(years == 1 ? "" : "s")",
                                    value: binding({ $0.retention[i].keepYears ?? 1 }, { $0.retention[i].keepYears = $1 }), in: 1...30)
                        }
                        TextField("Why", text: binding({ $0.retention[i].reason }, { $0.retention[i].reason = $1 }))
                        Button("Remove", role: .destructive) { changed { $0.retention.remove(at: i) }; expanded = nil }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ConditionEditor.summary(rules[i].condition))
                        Text(priority(i) + (rules[i].keepYears.map { "\($0) year\($0 == 1 ? "" : "s")" } ?? "Indefinitely"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onMove(perform: byName ? nil : { from, to in changed { $0.retention.move(fromOffsets: from, toOffset: to) }; expanded = nil })
            Button {
                changed { $0.retention.insert(RetentionRule(condition: FacetCondition(types: ["Receipt"]), keepYears: 1), at: 0) }
                expanded = 0
            } label: { Label("Add Keep Period", systemImage: "plus") }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: Tags

    private var tags: some View {
        let list = config?.suggestedTags ?? []
        return List {
            Text("Tags the model prefers (it may add others). A folder rule or keep period can match on any tag.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(rows(list.count), id: \.self) { i in
                HStack {
                    TextField("Tag", text: binding({ $0.suggestedTags[i].tag }, { $0.suggestedTags[i].tag = $1.lowercased().replacingOccurrences(of: " ", with: "-") }))
                        .frame(width: 150)
                    TextField("What it's for", text: binding({ $0.suggestedTags[i].description }, { $0.suggestedTags[i].description = $1 }))
                    Button { changed { $0.suggestedTags.remove(at: i) } } label: {
                        Image(systemName: "minus.circle").accessibilityLabel("Remove tag")
                    }
                        .buttonStyle(.borderless)
                        .help("Remove this tag")
                }
            }
            Button { changed { $0.suggestedTags.append((tag: "new-tag", description: "")) } } label: {
                Label("Add Tag", systemImage: "plus")
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}

/// Which documents a rule applies to: an area, document types, and tags — each optional.
struct ConditionEditor: View {
    @Binding var condition: FacetCondition
    let taxonomy: TaxonomyConfig

    var body: some View {
        Picker("Area", selection: Binding(get: { condition.area ?? "" }, set: { condition.area = $0.isEmpty ? nil : $0 })) {
            Text("Any").tag("")
            ForEach(Self.alphabetical(taxonomy.areas.map(\.name)), id: \.self) { Text($0).tag($0) }
        }
        LabeledContent("Types") {
            Menu(condition.types?.joined(separator: ", ") ?? "Any") {
                Button("Any") { condition.types = nil }
                Divider()
                ForEach(Self.alphabetical(taxonomy.documentTypes.map(\.name)), id: \.self) { type in
                    Toggle(type, isOn: Binding(get: { condition.types?.contains(type) ?? false }, set: { on in
                        var types = condition.types ?? []
                        if on { types.append(type) } else { types.removeAll { $0 == type } }
                        condition.types = types.isEmpty ? nil : types
                    }))
                }
            }
            .fixedSize()
        }
        TextField("Any of these tags", text: Binding(
            get: { condition.tagsAny?.joined(separator: ", ") ?? "" },
            set: { text in
                let tags = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                condition.tagsAny = tags.isEmpty ? nil : tags
            }), prompt: Text("e.g. tolls, maintenance"))
    }

    /// A to Z, with the catch-all "Other" last.
    static func alphabetical(_ names: [String]) -> [String] {
        names.sorted { a, b in
            let (aOther, bOther) = (a == "Other", b == "Other")
            return aOther != bOther ? bOther : a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    static func summary(_ c: FacetCondition) -> String {
        var parts: [String] = []
        if let area = c.area { parts.append(area) }
        if let types = c.types { parts.append(types.joined(separator: " or ")) }
        if let tags = c.tagsAny { parts.append("tagged " + tags.joined(separator: " or ")) }
        return parts.isEmpty ? "Every document" : parts.joined(separator: " · ")
    }
}

/// Moves documents already filed to where the rules in use put them — a preview first, nothing
/// re-read by a model, and one ⌘Z to put them all back.
struct RefileSheet: View {
    let model: HomeClerkModel
    /// The rules as shown in Settings, which may be newer than the ones watching started with
    let taxonomy: TaxonomyConfig
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @State private var moves: [RefileMove] = []
    @State private var chosen = Set<String>()
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apply Rules to Filed Documents").font(.title2.weight(.semibold))
            Text(moves.isEmpty ? "Every filed document is already where the rules put it."
                 : "\(moves.count) document\(moves.count == 1 ? "" : "s") would move or be renamed. Untick any you placed by hand.")
                .foregroundStyle(.secondary)
            List(moves) { move in
                Toggle(isOn: Binding(get: { chosen.contains(move.id) },
                                     set: { if $0 { chosen.insert(move.id) } else { chosen.remove(move.id) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(FiledScreen.title(move.entry)).lineLimit(1)
                        Text(move.fromFolder == move.toFolder ? "Renamed to \(move.toName)" : "\(move.fromFolder) → \(move.toFolder)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .frame(height: 300)
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move \(chosen.count)") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            moves = model.reviewActions(using: taxonomy)?.refileMoves(model.library.documents) ?? []
            chosen = Set(moves.map(\.id))
        }
    }

    private func apply() {
        guard let actions = model.reviewActions(using: taxonomy) else { return }
        let entries = moves.filter { chosen.contains($0.id) }.map(\.entry)
        working = true
        Task {
            var refilings: [ReviewActions.Refiling] = [], failures: [any Error] = []
            for entry in entries {
                do { refilings.append(try await actions.refile(entry, facets: entry.facets, folder: nil)) } catch { failures.append(error) }
            }
            model.reportSkipped(failures, of: entries.count, "moved")
            let model = model
            undoManager?.registerUndo(withTarget: model) { model in
                MainActor.assumeIsolated {
                    model.undoRefilings(refilings, action: "Apply Rules")
                }
            }
            undoManager?.setActionName("Apply Rules")
            model.documentsChanged += 1
            model.updateSpotlight()
            working = false
            dismiss()
        }
    }
}
