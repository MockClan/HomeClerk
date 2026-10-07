// Filed: everything HomeClerk has filed, newest first, in a Mail-style list with details.

import AppKit
import HomeClerkKit
import PDFKit
import QuickLook
import SwiftUI

/// Everything HomeClerk has filed, newest first, with where each went and what HomeClerk made of
/// it — the record that outlasts Activity, which only covers this session.
struct FiledScreen: View {
    let model: HomeClerkModel
    @State private var documents: [DocumentIndex.Entry] = []
    @State private var selection: String?
    @State private var preview: URL?
    @AppStorage(DefaultsKey.filedInspector) private var showInspector = true
    @Environment(\.undoManager) private var undoManager
    /// Editing the selected document's details, as Contacts edits a card.
    @State private var editing = false
    @State private var draft = DocumentFacets()
    @State private var folder = ""
    @State private var problem: String?
    @State private var saving = false
    @State private var editOriginal: DocumentIndex.Entry?
    @State private var editOriginalFolder = ""
    @State private var editDraftKey = ""
    @AppStorage(DefaultsKey.filedListWidth) private var listWidth = 320.0

    private var selected: DocumentIndex.Entry? { documents.first { $0.path == selection } }

    var body: some View {
        Page(title: "Filed", subtitle: documents.isEmpty ? "Nothing filed yet"
             : documents.count == 1 ? "1 document" : "\(documents.count) documents") {
          VStack(spacing: 0) {
            if let suggestion = model.suggestion {
                SuggestionBanner(model: model, suggestion: suggestion)
                Divider()
            }
            if documents.isEmpty {
                ContentUnavailableView("Nothing filed yet", systemImage: "archivebox",
                                       description: Text("Each document HomeClerk files shows up here with where it went."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(groups, id: \.title) { group in
                            SwiftUI.Section(group.title) {
                                ForEach(group.documents) { entry in
                                    row(entry)
                                        .tag(entry.path)
                                        .contextMenu { FileMenu(path: entry.path, preview: $preview) }
                                        .onDrag { FileDrag.provider(entry.path) }
                                }
                            }
                        }
                    }
                    .disabled(saving)
                    .listStyle(.inset)
                    .frame(minWidth: 200, idealWidth: listWidth, maxWidth: listWidth)
                    .layoutPriority(1)
                    .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { paths in
                        for path in paths { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    }
                    .quickLookOnSpace(selected: selection.map { URL(fileURLWithPath: $0) },
                                      all: documents.map { URL(fileURLWithPath: $0.path) }, preview: $preview)

                    ResizableDivider(width: $listWidth)

                    if let entry = selected {
                        PDFPreview(url: URL(fileURLWithPath: entry.path))
                            .frame(minWidth: 160, maxWidth: .infinity, maxHeight: .infinity)
                        if showInspector {
                            Divider()
                            details(entry)
                                .frame(width: 280)
                                .transition(.move(edge: .trailing))
                        }
                    } else {
                        ContentUnavailableView("No Selection", systemImage: "doc",
                                               description: Text("Choose a document to see where it went and why."))
                    }
                }
            }
          }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { withAnimation { showInspector.toggle() } } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help(showInspector ? "Hide the inspector (⌥⌘I)" : "Show the inspector (⌥⌘I)")
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.filed) { load() }
        .onChange(of: model.needsReview) { load() }   // filing from Review, or undoing it
        .onChange(of: model.focusedDocument) { focus() }
        .onChange(of: model.documentsChanged) { load() }
        .onChange(of: selection) {
            preserveDraft()
            editing = false
            problem = nil
            if let entry = selected {
                model.lastFiledDocumentID = entry.documentID
                if model.filedDrafts[model.draftKey(entry.documentID)] != nil { startEditing(entry) }
            }
        }
        .onChange(of: draft) { preserveDraft() }
        .onChange(of: folder) { preserveDraft() }
        .onDisappear { preserveDraft() }
    }

    private func load() {
        documents = model.library.documents.sorted { $0.filedAt > $1.filedAt }
        focus()
        if selection == nil || selected == nil {
            selection = documents.first(where: { $0.documentID == model.lastFiledDocumentID })?.path ?? documents.first?.path
        }
    }

    /// Selects the document Activity asked to show.
    private func focus() {
        guard let path = model.focusedDocument, let entry = documents.first(where: { $0.path == path }) else { return }
        selection = path
        model.focusedDocument = nil
        if model.editWhenFocused {
            model.editWhenFocused = false
            // After the selection change has reset editing
            Task { @MainActor in
                guard selection == entry.path, !saving else { return }
                startEditing(entry)
            }
        }
    }

    /// Today, Yesterday, the last 7 days, then by month — as Mail and Finder's Recents group.
    private var groups: [(title: String, documents: [DocumentIndex.Entry])] {
        let calendar = Calendar.current
        var result: [(title: String, documents: [DocumentIndex.Entry])] = []
        for entry in documents {
            let title: String
            if calendar.isDateInToday(entry.filedAt) { title = "Today" }
            else if calendar.isDateInYesterday(entry.filedAt) { title = "Yesterday" }
            else if let days = calendar.dateComponents([.day], from: entry.filedAt, to: .now).day, days < 7 { title = "Previous 7 Days" }
            else { title = entry.filedAt.formatted(.dateTime.month(.wide).year()) }
            if result.last?.title == title { result[result.count - 1].documents.append(entry) }
            else { result.append((title, [entry])) }
        }
        return result
    }

    /// Laid out like a message in Mail: who it's from and when, what it is, then a preview.
    private func row(_ entry: DocumentIndex.Entry) -> some View {
        let f = entry.facets
        let vendor = FinishingPlan.readable(f.vendor)
        let what = [FinishingPlan.readable(f.description), f.amount.map(FinishingPlan.currency)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(vendor.isEmpty ? (entry.path as NSString).lastPathComponent : vendor)
                    .font(.headline).lineLimit(1)
                Spacer(minLength: 6)
                Text(Self.when(entry.filedAt)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            if !what.isEmpty { Text(what).lineLimit(1) }
            Label(Self.folder(entry), systemImage: "folder")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if !entry.summary.isEmpty {
                Text(entry.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    /// As Mail dates its messages: the time today, "Yesterday", the weekday this week, else the date.
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    static func title(_ entry: DocumentIndex.Entry) -> String {
        let parts = [entry.facets.vendor, entry.facets.description].map(FinishingPlan.readable).filter { !$0.isEmpty }
        return parts.isEmpty ? (entry.path as NSString).lastPathComponent : parts.joined(separator: " — ")
    }

    static func folder(_ entry: DocumentIndex.Entry) -> String {
        ((entry.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }

    @ViewBuilder
    private func details(_ entry: DocumentIndex.Entry) -> some View {
        if editing {
            Form {
                FacetEditor(model: model, facets: $draft, folder: $folder)
                SwiftUI.Section {
                    HStack {
                        Button("Save") { save(entry) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!FacetEditor.datesValid(draft))
                            .keyboardShortcut("s", modifiers: .command)
                        Button("Cancel") { cancelEditing() }
                            .keyboardShortcut(.cancelAction)
                    }
                } footer: {
                    Text(problem ?? "Saving renames and moves the file to match. ⌘Z undoes it.")
                        .foregroundStyle(problem == nil ? Color.secondary : Color.red)
                }
            }
            .formStyle(.grouped)
            .disabled(saving || model.documentIsBusy(entry.path))
        } else {
            summary(entry)
        }
    }

    private func startEditing(_ entry: DocumentIndex.Entry) {
        guard !saving, !model.documentIsBusy(entry.path) else { return }
        editDraftKey = model.draftKey(entry.documentID)
        if let saved = model.filedDrafts[model.draftKey(entry.documentID)] {
            editOriginal = saved.original
            editOriginalFolder = saved.originalFolder
            draft = saved.facets
            folder = saved.folder
            editing = true
            problem = saved.original == entry ? nil : "This document changed while your draft was kept. Cancel to reload its current details."
            return
        }
        editOriginal = entry
        draft = entry.facets
        // Keep a folder you chose earlier; otherwise let the rules decide
        let current = Self.folder(entry)
        folder = current == model.reviewActions?.destination(entry.facets).folder ? "" : current
        editOriginalFolder = folder
        problem = nil
        editing = true
    }

    private var draftChanged: Bool {
        guard let original = editOriginal else { return false }
        return draft != original.facets || folder != editOriginalFolder
    }
    private func preserveDraft() {
        guard editing, let original = editOriginal else { return }
        let key = editDraftKey
        if draftChanged {
            model.filedDrafts[key] = .init(original: original, facets: draft, folder: folder, originalFolder: editOriginalFolder)
        } else { model.filedDrafts[key] = nil }
    }
    private func cancelEditing() {
        guard !saving, !draftChanged || model.confirmDiscardEdits() else { return }
        model.filedDrafts[editDraftKey] = nil
        editing = false
        problem = nil
    }

    /// Renames and moves the document to match the corrected details, then asks whether the
    /// correction should teach HomeClerk anything. ⌘Z puts it back.
    private func save(_ entry: DocumentIndex.Entry) {
        guard !saving, let actions = model.reviewActions else { return }
        guard editOriginal == entry else { problem = "This document changed. Cancel to reload before saving."; return }
        guard model.beginDocumentAction([entry.path]) else { return }
        saving = true
        let key = model.draftKey(entry.documentID)
        let facets = draft, chosen = folder
        Task {
            defer { saving = false; model.endDocumentAction([entry.path]) }
            do {
                let refiling = try await actions.refile(entry, facets: facets, folder: chosen.isEmpty ? nil : chosen)
                undoManager?.registerUndo(withTarget: model) { model in
                    MainActor.assumeIsolated {
                        model.undoRefilings([refiling], action: "Edit Details", focus: refiling.before.path)
                    }
                }
                undoManager?.setActionName("Edit Details")
                model.filedDrafts[key] = nil
                editing = false
                model.suggest(from: entry.facets, to: facets)
                model.focusedDocument = refiling.after.path
                model.documentsChanged += 1
                model.updateSpotlight()
            } catch {
                problem = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }

    /// Where it went, where it came from, and what HomeClerk read from it.
    private func summary(_ entry: DocumentIndex.Entry) -> some View {
        let f = entry.facets
        let facts: [(String, String)] = [
            ("Type", FinishingPlan.readable(f.documentType)), ("Area", FinishingPlan.readable(f.area)),
            ("Vendor", FinishingPlan.readable(f.vendor)), ("Date", f.documentDate),
            ("Amount", f.amount.map(FinishingPlan.currency) ?? ""), ("Due", f.dueDate), ("Expires", f.expiresOn),
            ("Person", FinishingPlan.readable(f.person)), ("Vehicle", FinishingPlan.readable(f.vehicle)),
            ("Pet", FinishingPlan.readable(f.pet)), ("Tags", f.tags.joined(separator: ", "))
        ].filter { !$0.1.isEmpty }

        return Form {
            SwiftUI.Section("Filed") {
                LabeledContent("Folder", value: Self.folder(entry))
                LabeledContent("Name") { Text((entry.path as NSString).lastPathComponent).textSelection(.enabled) }
                LabeledContent("When", value: entry.filedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("From") { Text(Self.origin(entry.source)).textSelection(.enabled) }
                if !entry.model.isEmpty { LabeledContent("Analyzed by", value: entry.model) }
                if entry.confidence > 0 {
                    LabeledContent("Confidence", value: "\(Int((entry.confidence * 100).rounded()))%")
                }
            }
            if !entry.summary.isEmpty {
                SwiftUI.Section("Summary") { Text(entry.summary).textSelection(.enabled) }
            }
            if !facts.isEmpty {
                SwiftUI.Section("What HomeClerk read") {
                    ForEach(facts, id: \.0) { fact in
                        LabeledContent(fact.0) { Text(fact.1).textSelection(.enabled) }
                    }
                }
            }
            SwiftUI.Section {
                Button("Edit Details…") { startEditing(entry) }
                    .help("Correct what HomeClerk read; the file is renamed and moved to match")
                Button("Open in Preview") { NSWorkspace.shared.open(URL(fileURLWithPath: entry.path)) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
            }
        }
        .formStyle(.grouped)
    }

    /// "scan_0012.pdf" → the scan's name; "review:x.pdf" → "x.pdf, filed from Review".
    static func origin(_ source: String) -> String {
        if source.hasPrefix("review:") { return "\(source.dropFirst("review:".count)), filed from Review" }
        return source.isEmpty ? "Unknown" : source
    }
}
