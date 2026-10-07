// Review: scans HomeClerk wasn't sure about, to correct and file — split, combined, rotated,
// read again, or unlocked first.

import AppKit
import HomeClerkKit
import PDFKit
import QuickLook
import SwiftUI

struct ReviewScreen: View {
    let model: HomeClerkModel
    @Environment(\.undoManager) private var undoManager
    /// Scans and names selected; several scans can be filed together.
    @State private var selection = Set<String>()
    @State private var message: String?
    /// The selected scan's details as you've corrected them, and a folder you chose.
    @State private var draft = DocumentFacets()
    @State private var folder = ""
    @State private var draftFor: String?
    @State private var baseline: HomeClerkModel.ReviewDraft?
    @State private var working = false
    /// When the scan holds several documents: each one's pages and details, and the one being edited.
    @State private var parts: [FacetDocument] = []
    @State private var part = 0
    @State private var pageCount = 1
    /// The page showing, and a counter bumped when the scan is rotated so its preview reloads.
    @State private var currentPage = 0
    @State private var pdfRevision = 0
    @AppStorage(DefaultsKey.reviewInspector) private var showInspector = true
    @AppStorage(DefaultsKey.reviewListWidth) private var reviewListWidth = 240.0

    private static let noticedPrefix = "noticed:"

    private var single: String? { selection.count == 1 ? selection.first : nil }

    private var selectedNoticed: NoticedName? {
        // With no scans left, the first question is shown
        if selection.isEmpty { return model.pending.isEmpty ? model.noticed.first : nil }
        guard let single, single.hasPrefix(Self.noticedPrefix) else { return nil }
        return model.noticed.first { Self.noticedPrefix + $0.id == single }
    }

    private var selected: ReviewActions.PendingScan? {
        if selection.count > 1 || selectedNoticed != nil { return nil }
        return model.pending.first { $0.id == single } ?? (selection.isEmpty || model.noticed.isEmpty ? model.pending.first : nil)
    }

    /// Several scans selected, to file together.
    private var batch: [ReviewActions.PendingScan] {
        selection.count > 1 ? model.pending.filter { selection.contains($0.id) } : []
    }

    private var subtitle: String {
        let scans = model.pending.count, names = model.noticed.count
        var parts: [String] = []
        if scans > 0 { parts.append(scans == 1 ? "1 scan needs a decision" : "\(scans) scans need a decision") }
        if names > 0 { parts.append(names == 1 ? "1 name to confirm" : "\(names) names to confirm") }
        return parts.isEmpty ? "Nothing waiting" : parts.joined(separator: " · ")
    }

    private var page: some View {
        Page(title: "Review", subtitle: subtitle) {
            VStack(spacing: 0) {
                if let suggestion = model.suggestion {
                    SuggestionBanner(model: model, suggestion: suggestion)
                    Divider()
                }
                if model.pending.isEmpty && model.noticed.isEmpty {
                    ContentUnavailableView("Nothing to review", systemImage: "checkmark.seal",
                                           description: Text("Scans HomeClerk wasn't sure about, and names it hasn't met, show up here."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    panes
                }
            }
        }
    }

    var body: some View {
        page.toolbar {
            if let scan = selected {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { rotate(scan, -1, allPages: NSEvent.modifierFlags.contains(.option)) } label: {
                        Label("Rotate Left", systemImage: "rotate.left")
                    }
                    .help("Rotate this page left (⌘L); Option-click for every page. Keeps a PDF original; forms and signature fields are left unchanged.")
                    .disabled(working || model.documentIsBusy(scan.id))
                    Button { rotate(scan, 1, allPages: NSEvent.modifierFlags.contains(.option)) } label: {
                        Label("Rotate Right", systemImage: "rotate.right")
                    }
                    .help("Rotate this page right (⌘R); Option-click for every page. Keeps a PDF original; forms and signature fields are left unchanged.")
                    .disabled(working || model.documentIsBusy(scan.id))
                    Button {
                        NSWorkspace.shared.open(PDFTransformation.originalsFolder(for: scan.url))
                    } label: {
                        Label("PDF Originals", systemImage: "folder")
                    }
                    .help("Show copies saved before PDF transformations. Hidden beside the document; never automatically cleared.")
                    .disabled(!FileManager.default.fileExists(atPath: PDFTransformation.originalsFolder(for: scan.url).path))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { withAnimation { showInspector.toggle() } } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help(showInspector ? "Hide the inspector (⌥⌘I)" : "Show the inspector (⌥⌘I)")
            }
        }
        .focusedSceneValue(\.review, selected.map(commands))
        .onAppear {
            model.refreshReview()
            selection = model.lastReviewSelection.intersection(Set(model.pending.map(\.id)))
            resetDraft()
        }
        .onChange(of: selected?.id) { resetDraft() }
        .onChange(of: model.reviewDraftRevision) {
            if let id = draftFor, model.reviewDrafts[id] == nil {
                draftFor = nil
                resetDraft()
            }
        }
        .onChange(of: selection) { model.lastReviewSelection = selection }
        .onChange(of: draft) { preserveDraft() }
        .onChange(of: folder) { preserveDraft() }
        .onChange(of: parts) { preserveDraft() }
        .onChange(of: part) { preserveDraft() }
        .onDisappear { preserveDraft() }
    }

    /// The scans and names, the selected one's pages, and — as in Finder and Preview — an
    /// inspector with what HomeClerk made of it and what to do with it.
    private var panes: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                if !model.pending.isEmpty {
                    SwiftUI.Section("Scans") {
                        ForEach(model.pending) { scan in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(scan.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Text(scan.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .padding(.vertical, 2)
                            .accessibilityElement(children: .combine)
                            .tag(scan.id)
                            .contextMenu { menu(scan) }
                        }
                    }
                }
                if !model.noticed.isEmpty {
                    SwiftUI.Section("Noticed") {
                        ForEach(model.noticed) { name in
                            VStack(alignment: .leading, spacing: 2) {
                                Label(FinishingPlan.readable(name.value), systemImage: symbol(name.kind)).lineLimit(1)
                                Text(name.resembles.map { "Like \(FinishingPlan.readable($0))?" } ?? "New \(name.kind.singular)?")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .accessibilityElement(children: .combine)
                            .tag(Self.noticedPrefix + name.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
            // Up to the width you dragged it to, giving way when the window is narrow
            .frame(minWidth: 200, idealWidth: reviewListWidth, maxWidth: reviewListWidth)
            .disabled(working)
            .layoutPriority(1)

            ResizableDivider(width: $reviewListWidth)

            if !batch.isEmpty {
                batchPane(batch)
            } else if let scan = selected {
                Group {
                    if scan.reason == PDFTools.lockedReason {
                        UnlockPane(scan: scan.url) { analyzeAgain(scan) }
                            .disabled(working || model.documentIsBusy(scan.id))
                    } else {
                        PDFPreview(url: scan.url, revision: pdfRevision, page: $currentPage)
                    }
                }
                .frame(minWidth: 160, maxWidth: .infinity, maxHeight: .infinity)
                // Laid out here rather than with .inspector, whose split view loops on
                // layout beside the PDF view and crashes
                if showInspector {
                    Divider()
                    inspector(scan)
                        .frame(width: 300)
                        .transition(.move(edge: .trailing))
                }
            } else if let name = selectedNoticed {
                PDFPreview(url: URL(fileURLWithPath: name.path))
                    .frame(minWidth: 160, maxWidth: .infinity, maxHeight: .infinity)
                if showInspector {
                    Divider()
                    NoticedInspector(model: model, name: name)
                        .id(name.id)
                        .frame(width: 300)
                }
            } else {
                ContentUnavailableView("No Selection", systemImage: "doc")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func symbol(_ kind: HouseholdKind) -> String {
        switch kind {
        case .people: "person.crop.circle.badge.questionmark"
        case .groups: "person.3"
        case .vehicles: "car"
        case .pets: "pawprint"
        case .vendors: "building.2"
        }
    }

    private func resetDraft() {
        guard !working else { return }
        guard let scan = selected else { preserveDraft(); draftFor = nil; return }
        guard draftFor != scan.id else { return }
        preserveDraft()
        draftFor = scan.id
        let documents = scan.analysis?.documents ?? []
        let initial = HomeClerkModel.ReviewDraft(facets: scan.document?.facets ?? DocumentFacets(), folder: "",
            parts: documents.count > 1 ? documents : [], part: 0)
        baseline = initial
        let saved = model.reviewDrafts[scan.id] ?? initial
        draft = saved.facets
        folder = saved.folder
        parts = saved.parts
        part = min(saved.part, max(parts.count - 1, 0))
        pageCount = max(PDFDocument(url: scan.url)?.pageCount ?? 1, 1)
    }

    private func preserveDraft() {
        guard let id = draftFor, let baseline else { return }
        if let review = model.review, id.hasPrefix(review.path + "/"), !model.pending.contains(where: { $0.id == id }) {
            model.reviewDrafts[id] = nil
            return
        }
        if draft != baseline.facets || folder != baseline.folder || parts != baseline.parts {
            model.reviewDrafts[id] = .init(facets: draft, folder: folder, parts: parts, part: part)
        } else { model.reviewDrafts[id] = nil }
    }
    private func forgetDrafts(_ ids: [String]) {
        for id in ids { model.reviewDrafts[id] = nil }
        if let draftFor, ids.contains(draftFor) { self.draftFor = nil }
        model.reviewDraftRevision += 1
    }
    private func canDiscard(_ scans: [ReviewActions.PendingScan]) -> Bool {
        preserveDraft()
        return !scans.contains(where: { model.reviewDrafts[$0.id] != nil }) || model.confirmDiscardEdits()
    }

    private var splitting: Bool { parts.count > 1 }

    /// Whether you've changed anything HomeClerk proposed.
    private func edited(_ scan: ReviewActions.PendingScan) -> Bool {
        if splitting { return parts != (scan.analysis?.documents ?? []) }
        return !folder.isEmpty || draft != (scan.document?.facets ?? DocumentFacets())
    }

    /// What's wrong with the page ranges, if anything: every page in exactly one document.
    private var splitProblem: String? {
        guard splitting else { return nil }
        return FacetDocument.pageCoverageProblem(parts, pageCount: pageCount)
    }

    /// The details being edited: the scan's, or the selected document's when it's split.
    private var editing: Binding<DocumentFacets> {
        splitting ? Binding(get: { parts.indices.contains(part) ? parts[part].facets : DocumentFacets() },
                            set: { if parts.indices.contains(part) { parts[part].facets = $0 } })
                  : $draft
    }

    /// The scan's documents, each with its page range, when it holds more than one.
    @ViewBuilder
    private func splitSection(_ scan: ReviewActions.PendingScan) -> some View {
        if splitting {
            SwiftUI.Section {
                ForEach(parts.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        Image(systemName: i == part ? "pencil.circle.fill" : "doc")
                            .foregroundStyle(i == part ? Color.accentColor : Color.secondary)
                            .accessibilityLabel(i == part ? "Editing" : "Part")
                        Text(Self.partTitle(parts[i], i)).lineLimit(1)
                        Spacer()
                        Stepper(value: $parts[i].firstPage, in: 1...pageCount) { Text("\(parts[i].firstPage)").monospacedDigit() }
                            .labelsHidden()
                        Text("–")
                        Stepper(value: $parts[i].lastPage, in: 1...pageCount) { Text("\(parts[i].lastPage)").monospacedDigit() }
                            .labelsHidden()
                        Text("p. \(parts[i].firstPage)–\(parts[i].lastPage)").monospacedDigit().font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { part = i }
                    .contextMenu {
                        Button("Remove Document") { removePart(i) }
                    }
                }
                Button("Add Document") { addPart() }
            } header: {
                Text("Documents in this scan")
            } footer: {
                Text(splitProblem ?? "Click a document to edit its details. Each is filed separately.")
                    .foregroundStyle(splitProblem == nil ? Color.secondary : Color.red)
            }
        } else if pageCount > 1 {
            SwiftUI.Section {
                Button("Split into Separate Documents…") {
                    parts = [FacetDocument(firstPage: 1, lastPage: 1, facets: draft, confidence: scan.document?.confidence ?? 0),
                             FacetDocument(firstPage: 2, lastPage: pageCount, facets: DocumentFacets(), confidence: 0)]
                    part = 1
                }
                .help("For a scan that holds more than one document")
            }
        }
    }

    private static func partTitle(_ d: FacetDocument, _ i: Int) -> String {
        let title = [d.facets.vendor, d.facets.description].map(FinishingPlan.readable).filter { !$0.isEmpty }.joined(separator: " — ")
        return title.isEmpty ? "Document \(i + 1)" : title
    }

    /// Splits the last document's pages to make a new one.
    private func addPart() {
        guard var last = parts.last else { return }
        let start = last.lastPage > last.firstPage ? last.lastPage : min(last.lastPage + 1, pageCount)
        if last.lastPage > last.firstPage { last.lastPage -= 1; parts[parts.count - 1] = last }
        parts.append(FacetDocument(firstPage: start, lastPage: pageCount, facets: DocumentFacets(), confidence: 0))
        part = parts.count - 1
    }

    private func removePart(_ i: Int) {
        parts.remove(at: i)
        if parts.count == 1 {
            // Back to one document: it gets the whole scan
            draft = parts[0].facets
            parts = []
        }
        part = min(part, max(parts.count - 1, 0))
    }

    /// Why it's here, the details HomeClerk read (yours to correct), and where it'll go.
    private func inspector(_ scan: ReviewActions.PendingScan) -> some View {
        Form {
            SwiftUI.Section("Why it's here") {
                Text(scan.reason)
                if let summary = scan.analysis?.summary, !summary.isEmpty {
                    Text(summary).foregroundStyle(.secondary)
                }
                if let document = scan.document {
                    LabeledContent("Confidence", value: "\(Int((document.confidence * 100).rounded()))%")
                }
            }

            splitSection(scan)

            FacetEditor(model: model, facets: editing, folder: $folder)

            SwiftUI.Section {
                HStack {
                    Button(fileTitle(scan)) { file(scan) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canFile(scan))
                        .help(canFile(scan) ? "File it with these details (⌘↩)"
                              : FacetEditor.datesValid(draft) ? "Fill in the details or choose a folder first" : "Fix the dates shown in red first")
                    if edited(scan) {
                        Button("Revert") {
                            guard canDiscard([scan]) else { return }
                            forgetDrafts([scan.id]); resetDraft()
                        }
                    }
                }
                if let provider = model.reading[scan.url.path] {
                    HStack { ProgressView().controlSize(.small); Text("Reading again with \(provider.rawValue)…").foregroundStyle(.secondary) }
                } else {
                    readAgainMenu([scan])
                }
                Button("Open in Preview") { NSWorkspace.shared.open(scan.url) }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !splitting && Self.isBare(draft) && canFile(scan) {
                        Label("With no vendor, description, or date, its file name will say almost nothing. It'll be listed in Tidy Up ▸ Needs Details until it has them.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if let message { Text(message).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(working || model.documentIsBusy(scan.id))
    }

    /// Read the scans again with a model of your choosing — Claude for one the local model
    /// struggled with, say — or send them back through the inbox.
    private func readAgainMenu(_ scans: [ReviewActions.PendingScan]) -> some View {
        Menu("Read Again") {
            ReadAgainButtons { readAgain(scans, $0) }
            Divider()
            Button("Send Back to the Inbox") { sendBackToInbox(scans) }
        }
        .fixedSize()
    }

    private func readAgain(_ scans: [ReviewActions.PendingScan], _ provider: AIProvider) {
        guard !working, !scans.contains(where: { model.documentIsBusy($0.id) }), canDiscard(scans) else { return }
        working = true
        Task {
            defer { working = false; resetDraft() }
            for scan in scans {
                if await model.readAgain(scan.url, with: provider) { forgetDrafts([scan.id]) }
            }
        }
    }

    /// Several scans selected: file the ones with a proposal together, or read them again.
    private func batchPane(_ scans: [ReviewActions.PendingScan]) -> some View {
        let ready = scans.filter { $0.document != nil && $0.analysis != nil }
        return VStack(spacing: 14) {
            Image(systemName: "doc.on.doc").font(.system(size: 40)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("\(scans.count) scans selected").font(.title3.weight(.semibold))
            Button("File \(ready.count) as Proposed") { fileAll(ready) }
                .buttonStyle(.borderedProminent)
                .disabled(ready.isEmpty)
            if ready.count < scans.count {
                Text("\(scans.count - ready.count) without a single proposed document — file those one at a time.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button("Combine into One Document") { combine(scans) }
                .help("For one document saved as several scans: joins their pages, in this list's order, into one scan")
            readAgainMenu(scans)
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(working || scans.contains(where: { model.documentIsBusy($0.id) }))
    }

    /// Joins the selected scans, in the list's order, into one scan in Review; ⌘Z separates them again.
    private func combine(_ scans: [ReviewActions.PendingScan]) {
        guard !working, let actions = model.reviewActions, canDiscard(scans), model.beginDocumentAction(scans.map(\.id)) else { return }
        defer { model.endDocumentAction(scans.map(\.id)) }
        do {
            let combination = try actions.combine(scans.map(\.url))
            let model = model
            undoManager?.registerUndo(withTarget: model) { model in
                MainActor.assumeIsolated {
                    model.undoStep("Combine Scans") { try model.reviewActions?.undo(combination) }
                    model.refreshReview()
                }
            }
            undoManager?.setActionName("Combine Scans")
            forgetDrafts(scans.map(\.id))
            model.refreshReview()
            selection = [combination.scan.path]
            draftFor = nil
            message = nil
        } catch {
            message = "Couldn't combine them: \(error)"
        }
    }

    /// Files each as proposed; one ⌘Z puts them all back.
    private func fileAll(_ scans: [ReviewActions.PendingScan]) {
        guard !working, let actions = model.reviewActions, canDiscard(scans), model.beginDocumentAction(scans.map(\.id)) else { return }
        working = true
        Task {
            defer { working = false; model.endDocumentAction(scans.map(\.id)); resetDraft() }
            var filings: [ReviewActions.Filing] = [], failures: [any Error] = []
            for scan in scans {
                guard let document = scan.document, let analysis = scan.analysis else { continue }
                do {
                    filings.append(try await actions.fileAsProposed(scan.url, document: document, analysis: analysis))
                } catch {
                    failures.append(error)
                }
            }
            message = "Filed \(filings.count) of \(scans.count)"
                + (failures.first.map { ". The first that couldn't be filed: \($0.localizedDescription)" } ?? "")
            forgetDrafts(filings.map { $0.scan.path })
            selection = []
            let model = model
            undoManager?.registerUndo(withTarget: model) { model in
                MainActor.assumeIsolated {
                    for filing in filings.reversed() { model.undoStep("Filing") { _ = try model.reviewActions?.undo(filing) } }
                    model.refreshReview()
                    model.documentsChanged += 1
                }
            }
            undoManager?.setActionName("File \(filings.count) Scans")
            model.refreshReview()
            model.updateSpotlight()
            model.documentsChanged += 1
        }
    }

    @ViewBuilder
    private func menu(_ scan: ReviewActions.PendingScan) -> some View {
        if scan.document != nil { Button("File as Proposed") { fileAsProposed(scan) } }
        Button("Read Again with Claude") { readAgain([scan], .claude) }
        Button("Send Back to the Inbox") { analyzeAgain(scan) }
        Divider()
        Button("Open") { NSWorkspace.shared.open(scan.url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([scan.url]) }
    }

    /// Details too thin to name or place a document by.
    static func isBare(_ f: DocumentFacets) -> Bool {
        f.vendor.isEmpty && f.description.isEmpty && f.documentDate.isEmpty
    }

    /// "File as Proposed", "File", or — when there's nothing to go on — where it'll end up.
    private func fileTitle(_ scan: ReviewActions.PendingScan) -> String {
        if splitting { return "File \(parts.count) Documents" }
        if Self.isBare(draft), let actions = model.reviewActions {
            return "File in \(actions.destination(draft, folder: folder.isEmpty ? nil : folder).folder)"
        }
        return scan.document != nil && !edited(scan) ? "File as Proposed" : "File"
    }

    /// Something to file it with — a proposal, your details, or a folder — and no impossible dates.
    private func canFile(_ scan: ReviewActions.PendingScan) -> Bool {
        guard !working, !model.documentIsBusy(scan.id) else { return false }
        if splitting { return splitProblem == nil && parts.allSatisfy { FacetEditor.datesValid($0.facets) } }
        return (scan.document != nil || edited(scan)) && FacetEditor.datesValid(draft)
    }

    /// The selected scan's actions, for the Document menu.
    private func commands(_ scan: ReviewActions.PendingScan) -> ReviewCommands {
        ReviewCommands(fileAsProposed: canFile(scan) ? { file(scan) } : nil,
                       analyzeAgain: { analyzeAgain(scan) },
                       open: { NSWorkspace.shared.open(scan.url) },
                       showInFinder: { NSWorkspace.shared.activateFileViewerSelecting([scan.url]) },
                       rotate: { turns, all in rotate(scan, turns, allPages: all) })
    }

    /// Turns the page showing (or every page) a quarter turn; ⌘Z turns it back.
    private func rotate(_ scan: ReviewActions.PendingScan, _ quarterTurns: Int, allPages: Bool) {
        guard !working, !model.documentIsBusy(scan.id) else { return }
        let pages: Set<Int>? = allPages ? nil : [currentPage]
        do {
            let operation = try DocumentOperations.acquire([scan.url])
            defer { operation.release() }
            try PDFTools.rotate(scan.url, pages: pages, quarterTurns: quarterTurns)
            pdfRevision += 1
            let url = scan.url
            undoManager?.registerUndo(withTarget: model) { model in
                MainActor.assumeIsolated {
                    model.undoStep("Rotate") {
                        let operation = try DocumentOperations.acquire([url])
                        defer { operation.release() }
                        try PDFTools.rotate(url, pages: pages, quarterTurns: -quarterTurns)
                    }
                    pdfRevision += 1
                }
            }
            undoManager?.setActionName(quarterTurns < 0 ? "Rotate Left" : "Rotate Right")
        } catch {
            message = "Couldn't rotate it: \(error)"
        }
    }

    /// Files the scan as shown: as proposed when nothing changed, otherwise with your corrections
    /// — then asks whether the correction should teach HomeClerk anything.
    private func file(_ scan: ReviewActions.PendingScan) {
        guard !working, !model.documentIsBusy(scan.id) else { return }
        guard let actions = model.reviewActions else { return }
        if splitting { return fileSplit(scan, actions) }
        guard edited(scan) else { return fileAsProposed(scan) }
        let original = scan.document?.facets, facets = draft, chosen = folder
        if original == nil && facets == DocumentFacets() {
            // Nothing known about it: it keeps its name in the folder you chose
            file(scan) { try await actions.fileInFolder(scan.url, folder: chosen, document: nil, analysis: nil) }
            return
        }
        file(scan, onSuccess: { model.suggest(from: original, to: facets) }) {
            try await actions.fileEdited(scan.url, facets: facets, folder: chosen.isEmpty ? nil : chosen,
                                            analysis: scan.analysis, confidence: scan.document?.confidence ?? 0) }
    }

    /// Files each document in the scan separately. ⌘Z puts the scan back whole.
    private func fileSplit(_ scan: ReviewActions.PendingScan, _ actions: ReviewActions) {
        guard !working, model.beginDocumentAction([scan.id]) else { return }
        working = true
        let documents = parts
        Task {
            defer { working = false; model.endDocumentAction([scan.id]); resetDraft() }
            do {
                let split = try await actions.fileSplit(scan.url, documents: documents, analysis: scan.analysis)
                message = "Filed \(split.parts.count) documents"
                forgetDrafts([scan.id])
                selection = []
                let model = model
                undoManager?.registerUndo(withTarget: model) { model in
                    MainActor.assumeIsolated {
                        model.undoStep("Split") { try model.reviewActions?.undo(split) }
                        model.refreshReview()
                        model.documentsChanged += 1
                    }
                }
                undoManager?.setActionName("File \(split.parts.count) Documents")
                model.updateSpotlight()
                model.documentsChanged += 1
            } catch {
                message = "Couldn't split it: \(error)"
            }
            model.refreshReview()
        }
    }

    private func fileAsProposed(_ scan: ReviewActions.PendingScan) {
        guard !working, canDiscard([scan]) else { return }
        guard let document = scan.document, let analysis = scan.analysis, let actions = model.reviewActions else { return }
        file(scan) { try await actions.fileAsProposed(scan.url, document: document, analysis: analysis) }
    }

    private func analyzeAgain(_ scan: ReviewActions.PendingScan) {
        sendBackToInbox([scan])
    }

    /// Files the selected scan, then shows the next one. ⌘Z puts it back.
    private func file(_ scan: ReviewActions.PendingScan, onSuccess: (() -> Void)? = nil,
                      _ action: @escaping () async throws -> ReviewActions.Filing) {
        guard !working, model.beginDocumentAction([scan.id]) else { return }
        working = true
        Task {
            defer { working = false; model.endDocumentAction([scan.id]); resetDraft() }
            do {
                let filing = try await action()
                onSuccess?()
                message = "Filed in \(filing.destination.deletingLastPathComponent().lastPathComponent)"
                forgetDrafts([scan.id])
                selection = []
                let model = model
                undoManager?.registerUndo(withTarget: model) { model in
                    MainActor.assumeIsolated {
                        model.undoStep("Filing") { _ = try model.reviewActions?.undo(filing) }
                        model.documentsChanged += 1
                        model.refreshReview()
                    }
                }
                undoManager?.setActionName("File \(filing.scan.lastPathComponent)")
                model.documentsChanged += 1
                model.updateSpotlight()
            } catch {
                message = "Couldn't file it: \(error.localizedDescription)"
            }
            model.refreshReview()
        }
    }

    /// Runs an action on the selected scan, then shows the next one.
    private func sendBackToInbox(_ scans: [ReviewActions.PendingScan]) {
        guard !working, let actions = model.reviewActions, canDiscard(scans), model.beginDocumentAction(scans.map(\.id)) else { return }
        working = true
        Task {
            defer { working = false; model.endDocumentAction(scans.map(\.id)); resetDraft() }
            for scan in scans {
                do {
                    _ = try actions.sendBackToInbox(scan.url)
                    forgetDrafts([scan.id])
                    message = "Sent to the Inbox"
                } catch { message = "Couldn't do that: \(error.localizedDescription)" }
            }
            selection = []
            model.refreshReview()
        }
    }
}

/// The Document menu's actions on the scan selected in Review.
struct ReviewCommands {
    var fileAsProposed: (() -> Void)?
    var analyzeAgain: () -> Void
    var open: () -> Void
    var showInFinder: () -> Void
    /// Quarter turns clockwise (negative for counterclockwise); `allPages` or just the one showing.
    var rotate: (_ quarterTurns: Int, _ allPages: Bool) -> Void
}

struct ReviewCommandsKey: FocusedValueKey { typealias Value = ReviewCommands }

extension FocusedValues {
    var review: ReviewCommands? {
        get { self[ReviewCommandsKey.self] }
        set { self[ReviewCommandsKey.self] = newValue }
    }
}

/// A scan that needs a password: type it to unlock the PDF for good, and HomeClerk reads it from
/// the inbox again. The password is used once and not kept.
struct UnlockPane: View {
    let scan: URL
    let unlocked: () -> Void
    @State private var password = ""
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.doc").font(.system(size: 44)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("This PDF is password protected").font(.title3.weight(.semibold))
            Text("Banks and insurers often lock statements they email. Enter the password once and HomeClerk saves an unlocked copy, then reads and files it as usual. The password isn't kept. The encrypted original is saved in a hidden .homeclerk-pdf-originals folder beside this PDF, even when scanner-original storage is off. Unlocking redraws pages and may remove links, annotations, or bookmarks. PDFs with forms or signature fields are left unchanged.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            HStack {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .frame(width: 220)
                    .onSubmit(unlock)
                Button("Unlock", action: unlock)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
            }
            if let problem { Text(problem).foregroundStyle(.red) }
        }
        .padding()
        .onChange(of: scan) { password = ""; problem = nil }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        do {
            let operation = try DocumentOperations.acquire([scan])
            defer { operation.release() }
            try FileOrganizer.requireInside(scan, scan.deletingLastPathComponent())
            try PDFTools.unlock(scan, password: password)
            password = ""
            unlocked()
        } catch {
            problem = error.localizedDescription
        }
    }
}
