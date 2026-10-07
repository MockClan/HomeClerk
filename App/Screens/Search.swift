// Search: filed documents by their details or by the words printed on them, with saved searches.

import AppKit
import HomeClerkKit
import PDFKit
import QuickLook
import SwiftUI

/// A search you named, to run again from the Saved menu.
struct SavedSearch: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var query: String
    var filter: DocumentLibrary.Filter

    static func all() -> [SavedSearch] {
        (UserDefaults.standard.data(forKey: DefaultsKey.savedSearches)).flatMap { try? JSONDecoder().decode([SavedSearch].self, from: $0) } ?? []
    }

    static func save(_ searches: [SavedSearch]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(searches), forKey: DefaultsKey.savedSearches)
    }
}

struct SearchScreen: View {
    let model: HomeClerkModel
    @State private var query = ""
    @State private var filter = DocumentLibrary.Filter()
    @State private var results: [DocumentIndex.Entry] = []
    /// Documents found only by words printed on them, with the text around the match.
    @State private var inText: [String: String] = [:]
    @State private var textSearch: Task<Void, Never>?
    @State private var selection = Set<DocumentIndex.Entry.ID>()
    @State private var preview: URL?
    @State private var saved = SavedSearch.all()
    @State private var naming = false
    @State private var newName = ""

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty || !filter.isEmpty }

    var body: some View {
        Page(title: "Search", subtitle: !searching ? "Every filed document"
             : results.count == 1 ? "1 match" : "\(results.count) matches") {
          VStack(spacing: 0) {
            filters
            Divider()
            if !searching {
                ContentUnavailableView("Search filed documents", systemImage: "magnifyingglass",
                                       description: Text("Every word must match — vendor, person, vehicle, pet, tags, or date. For example: rav4 2026. Or pick a filter above."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(results, selection: $selection) {
                    TableColumn("Who or What") { entry in
                        // Who it's about, or for a household bill with no one in particular, who sent it
                        Text([entry.facets.person, entry.facets.vehicle, entry.facets.pet, entry.facets.vendor].map(FinishingPlan.readable)
                            .first { !$0.isEmpty } ?? "").foregroundStyle(.secondary).lineLimit(1)
                    }
                    .width(min: 70, ideal: 110)
                    TableColumn("Date") { Text($0.facets.documentDate.isEmpty ? "Undated" : $0.facets.documentDate).monospacedDigit() }
                        .width(min: 80, ideal: 90, max: 110)
                    TableColumn("Folder") { Text((($0.path as NSString).deletingLastPathComponent as NSString).lastPathComponent) }
                        .width(min: 120, ideal: 170)
                    TableColumn("Document") { entry in
                        VStack(alignment: .leading, spacing: 1) {
                            Text((entry.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                            // Found by a word printed on it rather than a detail HomeClerk read
                            if let snippet = inText[entry.path] {
                                Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .contextMenu { FileMenu(path: entry.path, preview: $preview) }
                        .onDrag { FileDrag.provider(entry.path) }
                    }
                }
                .columnsFitWithoutScrolling()
                .contextMenu(forSelectionType: DocumentIndex.Entry.ID.self) { _ in } primaryAction: { ids in
                    for path in ids.prefix(10) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                }
                .quickLookOnSpace(selected: selection.first.map { URL(fileURLWithPath: $0) },
                                  all: results.map { URL(fileURLWithPath: $0.path) }, preview: $preview)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Vendor, person, vehicle, tag…")
        .modifier(FocusSearchField(model: model))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(saved) { search in Button(search.name) { query = search.query; filter = search.filter } }
                    if !saved.isEmpty { Divider() }
                    Button("Save This Search…") { newName = query; naming = true }.disabled(!searching)
                    if !saved.isEmpty {
                        Menu("Delete") {
                            ForEach(saved) { search in
                                Button(search.name) { saved.removeAll { $0 == search }; SavedSearch.save(saved) }
                            }
                        }
                    }
                } label: { Label("Saved Searches", systemImage: "bookmark") }
                .help("Saved searches")
            }
        }
        .alert("Save Search", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                saved.removeAll { $0.name == name }
                saved.append(SavedSearch(name: name, query: query, filter: filter))
                SavedSearch.save(saved)
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("It'll be in the Saved Searches menu.") }
        .onChange(of: query) { search() }
        .onAppear { takeRequest(); search() }
        .onDisappear { textSearch?.cancel() }
        .onChange(of: model.searchRequest) { takeRequest() }
        .onChange(of: model.documentsChanged) { search() }
        .onChange(of: filter) { search() }
    }
}

/// Go ▸ Search Documents puts the cursor in the search field (macOS 15 and later can do so).
struct FocusSearchField: ViewModifier {
    let model: HomeClerkModel
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .searchFocused($focused)
                .onAppear { if model.focusSearch { focused = true; model.focusSearch = false } }
                .onChange(of: model.focusSearch) { if model.focusSearch { focused = true; model.focusSearch = false } }
        } else {
            content
        }
    }
}

extension SearchScreen {
    /// The details HomeClerk read are searched at once; the words printed in documents a moment later,
    /// in the background, so typing never waits on reading PDFs.
    /// Another section asked for a search: start it, with the filters cleared so it finds them all.
    private func takeRequest() {
        guard let request = model.searchRequest else { return }
        model.searchRequest = nil
        filter = DocumentLibrary.Filter()
        query = request
        search()
    }

    private func search() {
        let library = model.library
        let revision = model.documentsChanged
        selection.formIntersection(Set(library.documents.map(\.path)))
        results = library.find(query, filter: filter)
        inText = [:]
        textSearch?.cancel()
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return }
        let candidates = library.documents.filter { filter.matches($0.facets) && !results.map(\.path).contains($0.path) }
        let index = model.fullText
        textSearch = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let matches = await Task.detached(priority: .userInitiated) { index.search(words, in: candidates) }.value
            guard !Task.isCancelled, model.documentsChanged == revision else { return }
            results += matches.map(\.entry).sorted { $0.facets.documentDate > $1.facets.documentDate }
            inText = Dictionary(matches.map { ($0.entry.path, $0.snippet) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// Narrow by who or what it's about, the year, or the kind of document.
    private var filters: some View {
        let library = model.library
        return HStack(spacing: 12) {
            filterMenu("Person", $filter.person, library.choices(\.person))
            filterMenu("Vehicle", $filter.vehicle, library.choices(\.vehicle))
            filterMenu("Pet", $filter.pet, library.choices(\.pet))
            filterMenu("Year", $filter.year, library.years)
            filterMenu("Type", $filter.type, library.choices(\.documentType))
            Spacer()
            if !filter.isEmpty { Button("Clear") { filter = .init() }.controlSize(.small) }
        }
        .padding(.horizontal, Layout.margin)
        .padding(.vertical, 8)
    }

    private func filterMenu(_ title: String, _ value: Binding<String>, _ choices: [String]) -> some View {
        Picker(title, selection: value) {
            Text("Any \(title)").tag("")
            ForEach(choices, id: \.self) { Text(FinishingPlan.readable($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(choices.isEmpty)
    }
}
