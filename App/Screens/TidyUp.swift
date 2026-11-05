// Tidy Up — duplicates waiting for a decision, and filed documents past their keep period — and
// the tax-year export.

import AppKit
import HomeClerkKit
import PDFKit
import SwiftUI

extension HomeClerkModel {

    /// Documents you chose to keep past their keep period.
    var keeping: Set<String> { Set(UserDefaults.standard.stringArray(forKey: DefaultsKey.keepAnyway) ?? []) }


    /// Documents filed twice that you chose to keep both of, by pair.
    var keepingBoth: Set<String> { Set(UserDefaults.standard.stringArray(forKey: DefaultsKey.keepBothFiled) ?? []) }

    func keepBoth(_ pair: FiledDuplicate, undoManager: UndoManager?) {
        let before = keepingBoth
        UserDefaults.standard.set(Array(before.union([pair.id])), forKey: DefaultsKey.keepBothFiled)
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                UserDefaults.standard.set(Array(before), forKey: DefaultsKey.keepBothFiled)
                model.refreshTidy()
            }
        }
        undoManager?.setActionName("Keep Both")
        filedDuplicates.removeAll { $0.id == pair.id }
    }

    /// Keeps one filed copy and moves the other to the Trash; ⌘Z puts both back.
    func keepFiledCopy(_ keep: DocumentIndex.Entry, removing extra: DocumentIndex.Entry, undoManager: UndoManager?) {
        guard let actions = reviewActions, beginDocumentAction([keep.path, extra.path]) else { return }
        filedDuplicates.removeAll { [$0.keep.path, $0.extra.path].contains(extra.path) }
        Task {
            defer { endDocumentAction([keep.path, extra.path]); refreshTidy(); documentsChanged += 1; updateSpotlight() }
            do {
                let kept = try await actions.keep(keep, removing: extra)
                undoManager?.registerUndo(withTarget: self) { model in
                    MainActor.assumeIsolated {
                        Task {
                            do { try await model.reviewActions?.undo(kept) } catch {
                                model.record(.problem, "Couldn't undo Keep This One", error.localizedDescription, nil)
                            }
                            model.refreshTidy()
                            model.documentsChanged += 1
                        }
                    }
                }
                undoManager?.setActionName("Keep This One")
                tidyProblem = nil
            } catch {
                tidyProblem = "Couldn't keep that copy: \(error.localizedDescription)"
                record(.problem, "Couldn't keep that copy", error.localizedDescription, keep.path)
            }
        }
    }

    /// The scan set aside is the better one: it replaces the filed copy; ⌘Z puts the filed copy back.
    func keepScanInstead(_ item: DuplicateItem, undoManager: UndoManager?) {
        guard let actions = reviewActions, let filed = item.original,
              beginDocumentAction([item.url.path, filed.path]) else { return }
        Task {
            defer { endDocumentAction([item.url.path, filed.path]); refreshTidy(); documentsChanged += 1; updateSpotlight() }
            do {
                let replaced = try await actions.keepScanInstead(item)
                undoManager?.registerUndo(withTarget: self) { model in
                    MainActor.assumeIsolated {
                        model.undoStep("Keep This One") { try model.reviewActions?.undo(replaced) }
                        model.refreshTidy()
                        model.documentsChanged += 1
                    }
                }
                undoManager?.setActionName("Keep This One")
                tidyProblem = nil
            } catch {
                tidyProblem = "Couldn't keep the new scan: \(error.localizedDescription)"
                record(.problem, "Couldn't use the new scan", error.localizedDescription, item.url.path)
            }
        }
    }

    /// Pieces you said aren't one document, by suggestion.
    var keepingSeparate: Set<String> { Set(UserDefaults.standard.stringArray(forKey: DefaultsKey.keepSeparate) ?? []) }

    func keepSeparate(_ suggestion: JoinSuggestion, undoManager: UndoManager?) {
        let before = keepingSeparate
        UserDefaults.standard.set(Array(before.union([suggestion.id])), forKey: DefaultsKey.keepSeparate)
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                UserDefaults.standard.set(Array(before), forKey: DefaultsKey.keepSeparate)
                model.refreshTidy()
            }
        }
        undoManager?.setActionName("Keep Separate")
        joinSuggestions.removeAll { $0.id == suggestion.id }
    }

    /// Joins filed documents into the first, pages in order; the rest go to the Trash. ⌘Z separates them again.
    func combineFiled(_ pieces: [DocumentIndex.Entry], undoManager: UndoManager?) throws {
        guard let actions = reviewActions else { throw ReviewActions.LibraryActionError("HomeClerk isn't ready yet.") }
        let paths = pieces.map(\.path)
        guard beginDocumentAction(paths) else {
            throw ReviewActions.LibraryActionError("One of them is busy with something else. Try again in a moment.")
        }
        defer { endDocumentAction(paths) }
        let joined = try actions.join(pieces)
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.undoStep("Combine Documents") { try model.reviewActions?.undo(joined) }
                model.refreshTidy()
                model.documentsChanged += 1
            }
        }
        undoManager?.setActionName("Combine Documents")
        joinSuggestions.removeAll { suggestion in suggestion.pieces.contains { paths.contains($0.path) } }
        documentsChanged += 1
        updateSpotlight()
        refreshTidy()
    }

    /// Documents you chose to leave as they are in Needs Details.
    var leaving: Set<String> { Set(UserDefaults.standard.stringArray(forKey: DefaultsKey.leaveAsIs) ?? []) }

    func leaveAsIs(_ paths: [String], undoManager: UndoManager?) {
        let before = leaving
        UserDefaults.standard.set(Array(before.union(paths)), forKey: DefaultsKey.leaveAsIs)
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                UserDefaults.standard.set(Array(before), forKey: DefaultsKey.leaveAsIs)
                model.refreshTidy()
            }
        }
        undoManager?.setActionName("Leave As Is")
        refreshTidy()
    }

    /// Opens a document in Filed, ready to edit its details.
    func editDetails(_ path: String) {
        focusedDocument = path
        editWhenFocused = true
        section = .filed
    }

    /// Sends filed documents back to Review and reads them again with a chosen model; they're
    /// filed from Review, as usual, once the new reading is in.
    func readAgainFromFiled(_ paths: [String], with provider: AIProvider) {
        guard let actions = reviewActions else { return }
        let entries = library.documents.filter { paths.contains($0.path) }
        Task {
            var failures: [any Error] = []
            for entry in entries {
                do {
                    let returned = try actions.returnToReview(entry)
                    refreshReview()
                    await readAgain(returned.scan, with: provider)
                } catch {
                    failures.append(error)
                }
            }
            reportSkipped(failures, of: entries.count, "sent back to read again")
            refreshTidy()
            documentsChanged += 1
        }
        section = .review
    }

    func refreshTidy() {
        refreshBackupCoverage()
        needsDetails = taxonomy.map { library.needingDetails(taxonomy: $0, leaving: leaving) } ?? []
        let settings = currentSettings ?? SettingsStore.app.load()
        originalsVerification?.cancel()
        let documents = library.documents
        let verification = Task.detached(priority: .utility) {
            (Originals.clearable(in: settings.originalsFolder, documents: documents),
             Originals.olderCopies(in: settings.originalsFolder, documents: documents,
                                   pending: [settings.inboxFolder, settings.reviewFolder],
                                   fingerprints: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder)))
        }
        originalsVerification = verification
        Task {
            let (verified, older) = await verification.value
            guard !verification.isCancelled else { return }
            clearableOriginals = verified
            olderOriginals = older
        }
        duplicateItems = reviewActions?.duplicateItems() ?? []
        // Reading printed page numbers opens PDFs, so off the main thread
        piecesSearch?.cancel()
        let separate = keepingSeparate
        let search = Task.detached(priority: .utility) { Joining.suggestions(documents, keepingSeparate: separate) }
        piecesSearch = search
        tidyChecksRunning += 1
        Task {
            let found = await search.value
            tidyChecksRunning -= 1
            guard !search.isCancelled else { return }
            joinSuggestions = found
        }
        // Compares every filed document's text (cached for Search), so off the main thread too
        filedDuplicatesSearch?.cancel()
        let fullText = self.fullText, keeping = keepingBoth, threshold = settings.duplicateHammingThreshold
        let twice = Task.detached(priority: .utility) {
            FiledDuplicates.find(documents, texts: fullText.texts(of: documents), hammingThreshold: threshold, keepingBoth: keeping)
        }
        filedDuplicatesSearch = twice
        tidyChecksRunning += 1
        Task {
            let found = await twice.value
            tidyChecksRunning -= 1
            guard !twice.isCancelled else { return }
            filedDuplicates = found
        }
        let rules = taxonomy?.retention ?? []
        expiredDocuments = Retention.expired(library.documents, rules: rules, today: DocumentProcessor.localToday(),
                                             keeping: keeping)
    }

    /// Checks once per run what backs up the HomeClerk folder (it runs tmutil, so off the main thread).
    func refreshBackupCoverage() {
        guard backupCoverage == nil else { return }
        let folder = (currentSettings ?? SettingsStore.app.load()).basePath
        Task {
            let found = await Task.detached { BackupCheck.coverage(of: folder) }.value
            backupCoverage = found
        }
    }

    func keepAnyway(_ paths: [String], undoManager: UndoManager?) {
        let before = keeping
        UserDefaults.standard.set(Array(before.union(paths)), forKey: DefaultsKey.keepAnyway)
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                UserDefaults.standard.set(Array(before), forKey: DefaultsKey.keepAnyway)
                model.refreshTidy()
            }
        }
        undoManager?.setActionName("Keep")
        refreshTidy()
    }

    /// Adds keep-indefinitely rules for documents like these (same area and type) at the top of
    /// your keep periods, so Tidy Up stops suggesting them now and later. ⌘Z restores the rules.
    func keepAlwaysLike(_ paths: [String], undoManager: UndoManager?) throws {
        guard let current = taxonomy else { return }
        let picked = expiredDocuments.filter { paths.contains($0.entry.path) }.map(\.entry.facets)
        var updated = current
        updated.retention.insert(contentsOf: Retention.keepRules(like: picked), at: 0)
        let hadCustom = FileManager.default.fileExists(atPath: customTaxonomyURL.path)
        try saveRules(updated)
        expiredDocuments = Retention.expired(library.documents, rules: updated.retention,
                                             today: DocumentProcessor.localToday(), keeping: keeping)
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                try? hadCustom ? model.saveRules(current) : model.useBuiltInRules()
                model.expiredDocuments = Retention.expired(model.library.documents, rules: current.retention,
                                                           today: DocumentProcessor.localToday(), keeping: model.keeping)
            }
        }
        undoManager?.setActionName("Keep All Like This")
    }

    /// Moves files to the Trash (so Finder's Put Back works too); ⌘Z brings them back.
    /// Originals go only when verified — or, with `allowingOlderCopies` (after you confirmed), when
    /// they're older copies from before HomeClerk kept filing records.
    func moveToTrash(_ urls: [URL], undoManager: UndoManager?, allowingOlderCopies: Bool = false, after: (() -> Void)? = nil) {
        let settings = currentSettings ?? SettingsStore.app.load()
        let roots = [settings.outboxFolder, settings.reviewFolder, settings.duplicatesFolder, settings.originalsFolder]
        func safe(_ url: URL) -> Bool {
            roots.contains { FileOrganizer.isInside($0, settings.basePath) && FileOrganizer.isInside(url, $0) }
        }
        let includesOriginals = urls.contains { FileOrganizer.isInside($0, settings.originalsFolder) }
        var verifiedOriginals = includesOriginals
            ? Set(Originals.clearable(in: settings.originalsFolder, documents: library.documents).map { $0.url.resolvingSymlinksInPath().path })
            : Set<String>()
        if includesOriginals, allowingOlderCopies {
            verifiedOriginals.formUnion(Originals.olderCopies(in: settings.originalsFolder, documents: library.documents,
                                                              pending: [settings.inboxFolder, settings.reviewFolder],
                                                              fingerprints: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
                .map { $0.url.resolvingSymlinksInPath().path })
        }
        var restored: [(trashed: URL, original: URL)] = []
        let facets = Dictionary(library.documents.map { ($0.path, $0.facets) }, uniquingKeysWith: { $1 })
        for url in urls {
            guard safe(url) else {
                record(.problem, "Couldn't move to Trash", "The path is outside a managed folder or contains a symbolic link", url.path)
                continue
            }
            if FileOrganizer.isInside(url, settings.originalsFolder), !verifiedOriginals.contains(url.resolvingSymlinksInPath().path) {
                record(.problem, "Original preserved", "Its current filed outputs could not be verified for cleanup", url.path)
                continue
            }
            var trashed: NSURL?
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)) != nil, let trashed {
                restored.append((trashed as URL, url))
                // A filed document that's gone mustn't make a later rescan of it look like a duplicate
                reviewActions?.forgetFiled(url)
            }
        }
        after?()
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                for item in restored {
                    guard safe(item.original) else {
                        model.record(.problem, "Couldn't restore from Trash", "The destination contains a symbolic link or is outside a managed folder", item.original.path)
                        continue
                    }
                    try? FileManager.default.moveItem(at: item.trashed, to: item.original)
                    model.reviewActions?.rememberFiled(item.original, facets: facets[item.original.path])
                }
                model.refreshTidy()
                model.documentsChanged += 1
            }
        }
        undoManager?.setActionName("Move to Trash")
        refreshTidy()
        documentsChanged += 1
        updateSpotlight()
    }
}

struct TidyScreen: View {
    let model: HomeClerkModel
    enum Mode: String { case details, duplicates, pieces, expired, originals }
    @AppStorage(DefaultsKey.tidyMode) private var mode = Mode.duplicates
    @Environment(\.undoManager) private var undoManager
    @State private var duplicate: String?
    @State private var piece: String?
    @State private var expiredSelection = Set<String>()
    @State private var confirmKeepAlways = false
    @State private var detailsSelection = Set<String>()
    @State private var originalsSelection = Set<String>()
    @State private var problem: String?
    /// A copy with fewer pages than the other, waiting for you to confirm keeping it.
    @State private var fewerPages: (pages: Int, other: Int, keep: () -> Void)?
    @AppStorage(DefaultsKey.backupAcknowledged) private var backupAcknowledged = false
    @State private var confirmOlderCopies = false

    var body: some View {
        Page(title: "Tidy Up", subtitle: subtitle) {
            Picker("Show", selection: $mode) {
                Text("Needs Details (\(model.needsDetails.count))").tag(Mode.details)
                Text("Duplicates (\(model.duplicateItems.count + model.filedDuplicates.count))").tag(Mode.duplicates)
                Text("Filed in Parts (\(model.joinSuggestions.count))").tag(Mode.pieces)
                Text("Past Keep Period (\(model.expiredDocuments.count))").tag(Mode.expired)
                Text("Originals (\(model.clearableOriginals.count + model.olderOriginals.count))").tag(Mode.originals)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } content: {
            Group {
                switch mode {
                case .details: details
                case .duplicates: duplicates
                case .pieces: pieces
                case .expired: expired
                case .originals: originals
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.backupCoverage?.isEmpty == true, !backupAcknowledged { BackupBanner(acknowledged: $backupAcknowledged) }
            }
        }
        .onAppear {
            model.refreshTidy()
            openOnAListWithSomethingInIt()
        }
        // The library checks finish after Tidy Up opens
        .onChange(of: model.tidyChecksRunning) { _, running in if running == 0 { openOnAListWithSomethingInIt() } }
        .confirmationDialog("Keep the copy with fewer pages?", isPresented: Binding(get: { fewerPages != nil }, set: { if !$0 { fewerPages = nil } })) {
            Button("Keep It Anyway") { fewerPages?.keep(); fewerPages = nil }
            Button("Cancel", role: .cancel) { fewerPages = nil }
        } message: {
            if let fewerPages {
                Text("It has \(fewerPages.pages) \(fewerPages.pages == 1 ? "page" : "pages") and the other has \(fewerPages.other), so pages may be missing. The other copy goes to the Trash.")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Library Health", systemImage: "heart.text.square") { model.showLibraryHealth = true }
            }
        }
        .sheet(isPresented: Binding(get: { model.showLibraryHealth }, set: { model.showLibraryHealth = $0 })) {
            LibraryHealthView(model: model)
        }
    }

    private func openOnAListWithSomethingInIt() {
        let counts: [(Mode, Int)] = [(.details, model.needsDetails.count), (.duplicates, model.duplicateItems.count + model.filedDuplicates.count),
                                     (.pieces, model.joinSuggestions.count), (.expired, model.expiredDocuments.count)]
        if counts.first(where: { $0.0 == mode })?.1 == 0, let busy = counts.first(where: { $0.1 > 0 }) { mode = busy.0 }
    }

    private var subtitle: String {
        model.tidyCount == 0 ? "Nothing to tidy" : model.tidyCount == 1 ? "1 thing to look at" : "\(model.tidyCount) things to look at"
    }

    // MARK: Duplicates

    /// Every row in Duplicates, in list order: scans set aside, then documents filed twice.
    private var duplicateIDs: [String] { model.duplicateItems.map(\.id) + model.filedDuplicates.map(\.id) }

    /// After a row goes (kept, trashed, or kept both), the one that took its place is selected —
    /// so what's shown is always what's highlighted, and ⌘⌫ acts on what you see.
    private func reselect(_ selection: Binding<String?>, old: [String], new: [String]) {
        guard selection.wrappedValue.map(new.contains) != true else { return }
        let gone = selection.wrappedValue.flatMap(old.firstIndex(of:)) ?? 0
        selection.wrappedValue = new.isEmpty ? nil : new[min(gone, new.count - 1)]
    }

    @ViewBuilder
    private func checking(_ empty: some View) -> some View {
        if model.tidyChecksRunning > 0 {
            ProgressView("Checking your library…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            empty
        }
    }

    @ViewBuilder
    private var duplicates: some View {
        if model.duplicateItems.isEmpty && model.filedDuplicates.isEmpty {
            checking(ContentUnavailableView("No duplicates", systemImage: "doc.on.doc",
                                            description: Text("Scans HomeClerk recognizes as already filed, and documents it finds filed twice, wait here for you to choose which to keep.")))
        } else {
            HStack(spacing: 0) {
                List(selection: $duplicate) {
                    if !model.duplicateItems.isEmpty {
                        SwiftUI.Section("New scans already filed") {
                            ForEach(model.duplicateItems) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    Text("Same as \((item.originalLabel as NSString).lastPathComponent)")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .padding(.vertical, 2)
                                .accessibilityElement(children: .combine)
                                .tag(item.id)
                            }
                        }
                    }
                    if !model.filedDuplicates.isEmpty {
                        SwiftUI.Section("Filed twice") {
                            ForEach(model.filedDuplicates) { pair in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text((pair.keep.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    Text(pair.partial ? "Also filed in part" : "Also filed again")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .padding(.vertical, 2)
                                .accessibilityElement(children: .combine)
                                .tag(pair.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .frame(width: 240)

                Divider()

                if let pair = model.filedDuplicates.first(where: { $0.id == duplicate }) {
                    filedTwice(pair)
                } else if let item = model.duplicateItems.first(where: { $0.id == duplicate }) {
                    setAside(item)
                } else {
                    ContentUnavailableView("Choose one on the left", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onChange(of: duplicateIDs) { old, new in reselect($duplicate, old: old, new: new) }
            .onAppear { reselect($duplicate, old: [], new: duplicateIDs) }
        }
    }

    /// A new scan set aside as already filed, beside the filed copy.
    private func setAside(_ item: DuplicateItem) -> some View {
        VStack(spacing: 0) {
            // The two side by side, as you'd compare them on a desk
            HStack(spacing: 1) {
                copy("New scan", url: item.url) {
                    Button("Keep This One") { keep(fewerPages: item.url, than: item.original) { model.keepScanInstead(item, undoManager: undoManager) } }
                        .disabled(item.original == nil || item.wholePile)
                        .help(item.wholePile ? "This scan holds several documents, so it can't take one document's place"
                                             : "Puts this scan in place of the filed copy — same name, folder, and details — and moves the filed copy to the Trash")
                        .accessibilityLabel("Keep the new scan")
                }
                if let original = item.original {
                    copy("Filed copy", url: original) {
                        Button("Keep This One") { keep(fewerPages: original, than: item.url) { trashScan(item) } }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.delete, modifiers: .command)
                            .help("Moves the new scan to the Trash")
                            .accessibilityLabel("Keep the filed copy")
                    }
                } else {
                    ContentUnavailableView("The filed copy has moved", systemImage: "questionmark.folder",
                                           description: Text(item.originalLabel))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Text(item.wholePile ? "Every document in this scan is already filed." : "Keep the clearer, more complete one; the other goes to the Trash.")
                    .font(.callout).foregroundStyle(.secondary)
                problemText
                Spacer()
                Button("Not a Duplicate") { notADuplicate(item) }
                    .help("Moves it to Review to file as its own document")
            }
            .padding(.horizontal, Layout.margin)
            .padding(.vertical, 10)
        }
    }

    private func trashScan(_ item: DuplicateItem) {
        // Its notes go too, so ⌘Z brings back the whole thing
        let notes = [ReviewProposal.reasonURL(for: item.url), ReviewProposal.proposalURL(for: item.url)]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        model.moveToTrash([item.url] + notes, undoManager: undoManager)
    }

    /// Two filed copies of one paper, the more complete one first.
    private func filedTwice(_ pair: FiledDuplicate) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                copy("More complete", url: URL(fileURLWithPath: pair.keep.path)) {
                    Button("Keep This One") { model.keepFiledCopy(pair.keep, removing: pair.extra, undoManager: undoManager) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.delete, modifiers: .command)
                        .accessibilityLabel("Keep the more complete copy")
                }
                copy(pair.partial ? "Has only some of the pages" : "Other copy", url: URL(fileURLWithPath: pair.extra.path)) {
                    Button("Keep This One") {
                        keep(fewerPages: URL(fileURLWithPath: pair.extra.path), than: URL(fileURLWithPath: pair.keep.path)) {
                            model.keepFiledCopy(pair.extra, removing: pair.keep, undoManager: undoManager)
                        }
                    }
                    .accessibilityLabel("Keep the other copy")
                }
            }
            Divider()
            HStack {
                Text("Keep the clearer, more complete one; the other goes to the Trash.")
                    .font(.callout).foregroundStyle(.secondary)
                problemText
                Spacer()
                Button("Keep Both") { model.keepBoth(pair, undoManager: undoManager) }
                    .help("They're different documents; HomeClerk won't list these again")
            }
            .padding(.horizontal, Layout.margin)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var problemText: some View {
        if let problem = problem ?? model.tidyProblem { Text(problem).font(.callout).foregroundStyle(.red).lineLimit(2) }
    }

    /// Keeps a copy — after asking, when it has fewer pages than the other, since that usually
    /// means pages are missing.
    private func keep(fewerPages kept: URL, than other: URL?, _ action: @escaping () -> Void) {
        problem = nil
        model.tidyProblem = nil
        let pages = PDFDocument(url: kept)?.pageCount ?? 0, otherPages = other.flatMap { PDFDocument(url: $0)?.pageCount } ?? 0
        guard pages < otherPages else { return action() }
        fewerPages = (pages, otherPages, action)
    }

    /// "3 pages · 412 KB"
    nonisolated fileprivate static func size(of url: URL) -> String {
        let pages = PDFDocument(url: url)?.pageCount ?? 0
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return "\(pages) \(pages == 1 ? "page" : "pages") · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
    }

    /// One copy to choose: what it is, its pages and size, where it's filed, the page itself, and
    /// what you can do with it.
    private func copy<Actions: View>(_ title: String, url: URL, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 1) {
                Text(title).font(.caption.weight(.semibold))
                CopyFacts(url: url)
                Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            PDFPreview(url: url)
            actions().padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func notADuplicate(_ item: DuplicateItem) {
        do {
            _ = try model.reviewActions?.notADuplicate(item)
            model.refreshTidy()
            model.refreshReview()
            problem = nil
        } catch {
            problem = "Couldn't move it: \(error.localizedDescription)"
        }
    }

    // MARK: Documents filed in parts

    private var pieceIDs: [String] { model.joinSuggestions.map(\.id) }

    @ViewBuilder
    private var pieces: some View {
        if model.joinSuggestions.isEmpty {
            checking(ContentUnavailableView("Nothing filed in parts", systemImage: "doc.on.doc",
                                            description: Text("A document filed in parts — its first pages from one scan, the rest from another — shows up here to put back together.")))
        } else {
            HStack(spacing: 0) {
                List(model.joinSuggestions, selection: $piece) { suggestion in
                    VStack(alignment: .leading, spacing: 2) {
                        Text((suggestion.pieces[0].path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text("A \(suggestion.pageCount)-page document filed in \(suggestion.pieces.count) parts")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                    .tag(suggestion.id)
                }
                .listStyle(.inset)
                .frame(width: 240)

                Divider()

                if let suggestion = model.joinSuggestions.first(where: { $0.id == piece }) {
                    VStack(spacing: 0) {
                        HStack(spacing: 1) {
                            ForEach(Array(suggestion.pieces.enumerated()), id: \.element.path) { number, entry in
                                copy(number == 0 ? "First part" : "Then", url: URL(fileURLWithPath: entry.path)) { EmptyView() }
                            }
                        }
                        Divider()
                        HStack {
                            Text("Combined, it keeps the first part's name, folder, and details; the other part goes to the Trash.")
                                .font(.callout).foregroundStyle(.secondary)
                            problemText
                            Spacer()
                            Button("Keep Separate") { model.keepSeparate(suggestion, undoManager: undoManager) }
                                .help("They aren't one document; HomeClerk won't suggest these again")
                            Button("Combine") {
                                do {
                                    try model.combineFiled(suggestion.pieces, undoManager: undoManager)
                                    problem = nil
                                } catch {
                                    problem = "Couldn't combine them: \(error.localizedDescription)"
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return, modifiers: .command)
                        }
                        .padding(.horizontal, Layout.margin)
                        .padding(.vertical, 10)
                    }
                } else {
                    ContentUnavailableView("Choose one on the left", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onChange(of: pieceIDs) { old, new in reselect($piece, old: old, new: new) }
            .onAppear { reselect($piece, old: [], new: pieceIDs) }
        }
    }

    // MARK: Needs details

    @ViewBuilder
    private var details: some View {
        if model.needsDetails.isEmpty {
            ContentUnavailableView("Every document has details", systemImage: "checkmark.seal",
                                   description: Text("Documents filed with nothing to go on — no vendor or description, or in the catch-all folder — wait here to be finished."))
        } else {
            VStack(spacing: 0) {
                Table(model.needsDetails, selection: $detailsSelection) {
                    TableColumn("Document") { Text(($0.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle) }
                    TableColumn("Folder") { Text(FiledScreen.folder($0)).foregroundStyle(.secondary) }.width(min: 100, ideal: 150)
                    TableColumn("Filed") { Text($0.filedAt.formatted(date: .abbreviated, time: .omitted)).monospacedDigit() }
                        .width(min: 80, ideal: 100, max: 120)
                    TableColumn("What HomeClerk knows") { entry in
                        Text(entry.summary.isEmpty ? "Nothing" : entry.summary).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .columnsFitWithoutScrolling()
                .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { paths in
                    if let path = paths.first { model.editDetails(path) }
                }
                Divider()
                HStack {
                    Text("Double-click to fill in the details; HomeClerk renames and moves it to match.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Leave As Is") { model.leaveAsIs(Array(detailsSelection), undoManager: undoManager); detailsSelection = [] }
                        .help("Stop listing these")
                    Menu("Read Again") {
                        ReadAgainButtons { model.readAgainFromFiled(Array(detailsSelection), with: $0) }
                    }
                    .fixedSize()
                    .help("Sends them back to Review and reads them again")
                    Button("Edit Details…") { if let path = detailsSelection.first { model.editDetails(path) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(detailsSelection.count != 1)
                }
                .disabled(detailsSelection.isEmpty)
                .padding(.horizontal, Layout.margin)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: Originals

    @ViewBuilder
    private var originals: some View {
        let items = model.clearableOriginals
        VStack(spacing: 0) {
            if items.isEmpty {
                ContentUnavailableView("No verified originals to clear", systemImage: "doc.on.doc",
                                       description: Text("HomeClerk keeps a copy of each scan in _originals (Settings ▸ General). Copies older than 90 days appear here once HomeClerk has verified that everything in them was filed."))
            } else {
                Table(items, selection: $originalsSelection) {
                    TableColumn("Scan") { Text($0.url.lastPathComponent).lineLimit(1).truncationMode(.middle) }
                    TableColumn("Copied") { Text($0.copied.formatted(date: .abbreviated, time: .omitted)).monospacedDigit() }
                        .width(min: 90, ideal: 110, max: 130)
                    TableColumn("Size") { Text(ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file)).monospacedDigit() }
                        .width(min: 60, ideal: 80, max: 100)
                }
                .columnsFitWithoutScrolling()
                .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { paths in
                    for path in paths { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                }
                Divider()
                HStack {
                    let total = items.reduce(0) { $0 + $1.size }
                    Text("Verified copies older than 90 days (\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) in all). The filed documents stay.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Move Selected to Trash") {
                        model.moveToTrash(originalsSelection.map { URL(fileURLWithPath: $0) }, undoManager: undoManager)
                        originalsSelection = []
                    }
                    .disabled(originalsSelection.isEmpty)
                    Button("Move All to Trash") {
                        model.moveToTrash(items.map(\.url), undoManager: undoManager)
                        originalsSelection = []
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, Layout.margin)
                .padding(.vertical, 10)
            }
            let older = model.olderOriginals
            if !older.isEmpty {
                Divider()
                HStack {
                    let total = older.reduce(0) { $0 + $1.size }
                    Text("\(older.count == 1 ? "1 older copy" : "\(older.count) older copies") (\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))) from before HomeClerk kept filing records.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Move Older Copies to Trash…") { confirmOlderCopies = true }
                }
                .padding(.horizontal, Layout.margin)
                .padding(.vertical, 10)
                .confirmationDialog("Move \(older.count == 1 ? "1 older copy" : "\(older.count) older copies") to the Trash?",
                                    isPresented: $confirmOlderCopies) {
                    Button("Move to Trash", role: .destructive) { model.moveToTrash(older.map(\.url), undoManager: undoManager, allowingOlderCopies: true) }
                } message: {
                    Text("An earlier version of HomeClerk filed these scans without recording proof. Each matches a filed document by its scan's name, but HomeClerk can't check that every page was filed. They go to the Trash, so you can put them back.")
                }
            }
        }
    }

    // MARK: Past keep period

    @ViewBuilder
    private var expired: some View {
        if model.expiredDocuments.isEmpty {
            ContentUnavailableView("Nothing past its keep period", systemImage: "clock.badge.checkmark",
                                   description: Text("Documents show up here once they're older than worth keeping — a paid utility bill after a year, say. Change the periods in Settings ▸ Rules."))
        } else {
            VStack(spacing: 0) {
                Table(model.expiredDocuments, selection: $expiredSelection) {
                    TableColumn("Document") { Text(FiledScreen.title($0.entry)).lineLimit(1) }
                    TableColumn("Dated") { Text($0.entry.facets.documentDate).monospacedDigit() }.width(min: 80, ideal: 90, max: 100)
                    TableColumn("Kept until") { Text($0.keepUntil).monospacedDigit() }.width(min: 80, ideal: 90, max: 100)
                    TableColumn("Why it can go") { Text($0.reason).foregroundStyle(.secondary).lineLimit(1) }
                }
                .columnsFitWithoutScrolling()
                .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { paths in
                    for path in paths { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                }
                Divider()
                HStack {
                    if let problem {
                        Text(problem).font(.callout).foregroundStyle(.red)
                    } else {
                        Text("These are suggestions. Shred the paper originals too, if you kept them.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Keep") { model.keepAnyway(Array(expiredSelection), undoManager: undoManager); expiredSelection = [] }
                        .help("Keep these and stop suggesting them")
                    Button("Keep All Like This…") { confirmKeepAlways = true }
                        .help("Keep documents of the same kind indefinitely, now and in future")
                    Button("Move to Trash") {
                        model.moveToTrash(expiredSelection.map { URL(fileURLWithPath: $0) }, undoManager: undoManager)
                        expiredSelection = []
                    }
                    .buttonStyle(.borderedProminent)
                }
                .disabled(expiredSelection.isEmpty)
                .padding(.horizontal, Layout.margin)
                .padding(.vertical, 10)
            }
            .confirmationDialog(keepAlwaysTitle, isPresented: $confirmKeepAlways) {
                Button("Keep Indefinitely") {
                    do { try model.keepAlwaysLike(Array(expiredSelection), undoManager: undoManager) } catch { problem = "\(error)" }
                    expiredSelection = []
                }
            } message: {
                Text("Tidy Up stops suggesting these, now and in future. Change it any time in Settings ▸ Rules ▸ Keep Periods.")
            }
        }
    }

    /// "Always keep Vehicle receipts?", naming each kind selected.
    private var keepAlwaysTitle: String {
        let kinds = Retention.keepRules(like: model.expiredDocuments.filter { expiredSelection.contains($0.entry.path) }.map(\.entry.facets))
            .map { rule in
                let type = rule.condition.types?.first.map { $0.lowercased() + ($0.hasSuffix("s") ? "" : "s") } ?? "documents"
                return [rule.condition.area, type].compactMap { $0 }.joined(separator: " ")
            }
        return "Always keep \(ListFormatter.localizedString(byJoining: kinds))?"
    }
}

/// Explicit scans stay off the main actor; repairs show their exact scope before running.
private struct LibraryHealthView: View {
    let model: HomeClerkModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @State private var report = LibraryHealth.Report()
    @State private var selection: String?
    @State private var scanning = false
    @State private var repairing = false
    @State private var message: String?
    @State private var refresh = 0
    private var settings: HomeClerkSettings { model.currentSettings ?? SettingsStore.app.load() }
    private var selected: LibraryHealth.Issue? { report.issues.first { $0.id == selection } }
    /// Repairs wait for document work to finish; watching itself is paused and resumed for them.
    private var canRepair: Bool {
        model.state != .starting && model.state != .stopping && model.working.isEmpty
            && model.activeDocumentActions.isEmpty && model.reading.isEmpty && !scanning && !repairing
    }

    /// Repairs that are the same every time, so one confirmation can cover many. Interrupted
    /// filings and unsafe paths stay one at a time.
    private static let repeatable: Set<LibraryHealth.Kind> = [.unindexed, .missing, .staleDuplicate]

    /// What the repair button says, by kind.
    private static func action(_ kind: LibraryHealth.Kind) -> String {
        switch kind {
        case .missing: "Remove from Library"
        case .unindexed: "Add to Library"
        case .staleDuplicate: "Clear Match"
        case .pendingOperation: "Recover Filing"
        default: "Apply Repair"
        }
    }

    /// Everything Sync with Folders would do.
    private var syncable: [LibraryHealth.Issue] { report.issues.filter { Self.repeatable.contains($0.kind) && $0.preview != nil } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Library Health").font(.title2.weight(.semibold))
                    Text(scanning ? "Checking archive…" : "\(report.checkedPDFs) PDFs checked · \(report.issues.count) items to review")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if scanning { ProgressView().controlSize(.small) }
                Button("Sync with Folders…") { syncWithFolders() }
                    .disabled(syncable.isEmpty || !canRepair)
                    .help("Make the Library match what's in your folders: remove records whose PDF is gone, add PDFs that aren't recorded, and clear stale duplicate matches — one confirmation, one Undo")
                Button("Refresh") { refresh += 1 }.disabled(scanning || repairing)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(repairing)
            }.padding()
            Divider()
            HStack(spacing: 0) {
                List(report.issues, selection: $selection) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.title).font(.callout.weight(.medium))
                        Text((issue.path as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }.tag(issue.id)
                }.frame(width: 290).disabled(repairing)
                Divider()
                if let issue = selected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(issue.title).font(.headline)
                            Text(issue.path).font(.callout).textSelection(.enabled)
                            Text(issue.detail).font(.callout).textSelection(.enabled)
                            Button("Show Location in Finder") { showLocation(issue) }
                            if issue.kind == .finishing {
                                Button("Open Activity Repairs") {
                                    model.section = .activity
                                    model.refreshFinishing()
                                    model.showFinishingRepairs = true
                                    dismiss()
                                }
                            }
                            if let preview = issue.preview {
                                Divider()
                                Text("What \(Self.action(issue.kind)) does").font(.headline)
                                Text(preview).font(.callout)
                                if !canRepair && !repairing {
                                    Text("Waiting for document work to finish.").font(.callout).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Button(repairing ? "Working…" : Self.action(issue.kind) + "…") { run([issue]) }
                                        .buttonStyle(.borderedProminent).disabled(!canRepair)
                                    let alike = report.issues.filter { $0.kind == issue.kind && $0.preview != nil }
                                    if Self.repeatable.contains(issue.kind), alike.count > 1 {
                                        Button("All \(alike.count) Like This…") { run(alike) }
                                            .disabled(!canRepair)
                                            .help("The same for every item of this kind, with one confirmation and one Undo")
                                    }
                                }
                                Text("HomeClerk pauses watching while it repairs, then carries on.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxWidth: .infinity)
                } else {
                    ContentUnavailableView(scanning ? "Checking archive" : report.issues.isEmpty ? "No issues found" : "Choose an item",
                        systemImage: "heart.text.square", description: Text("Health checks inspect metadata and file presence. They do not verify every PDF's contents or your backup."))
                        .frame(maxWidth: .infinity)
                }
            }
            if let message { Divider(); Text(message).font(.callout).textSelection(.enabled).padding() }
        }
        .frame(minWidth: 820, minHeight: 540)
        .task(id: "\(refresh):\(model.documentsChanged):\(settings.basePath.path)") { await scan() }
    }

    private func scan() async {
        guard !repairing else { return }
        scanning = true
        let settings = settings
        let index = model.healthIndex
        let task = Task.detached(priority: .utility) { LibraryHealth.scan(settings: settings, index: index) }
        let found = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled else { return }
        report = found
        if !report.issues.contains(where: { $0.id == selection }) { selection = report.issues.first?.id }
        scanning = false
    }

    private func showLocation(_ issue: LibraryHealth.Issue) {
        let root = settings.basePath
        let file = URL(fileURLWithPath: issue.path)
        if FileOrganizer.isInside(file, root) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else { NSWorkspace.shared.activateFileViewerSelecting([root]) }
    }

    /// Make the Library match the folders, in one go.
    private func syncWithFolders() {
        let issues = syncable
        let counts = Dictionary(grouping: issues, by: \.kind).mapValues(\.count)
        var lines: [String] = []
        if let n = counts[.missing] { lines.append("Remove \(n) record\(n == 1 ? "" : "s") whose PDF is gone") }
        if let n = counts[.unindexed] { lines.append("Add \(n) PDF\(n == 1 ? "" : "s") that aren't recorded (details to fill in later, in Tidy Up ▸ Needs Details)") }
        if let n = counts[.staleDuplicate] { lines.append("Clear \(n) duplicate match\(n == 1 ? "" : "es") pointing at missing PDFs") }
        run(issues, title: "Sync the Library with your folders?",
            explanation: lines.map { "• " + $0 }.joined(separator: "\n")
                + "\n\nNo PDF is moved or deleted, and documents that are fine keep their details. One Undo puts it all back.")
    }

    /// One confirmation, then each repair in turn — re-checked first (LibraryHealth.repair
    /// rescans), off the main thread, stopping at the first failure — with watching paused and
    /// resumed, and one Undo for all of them.
    private func run(_ issues: [LibraryHealth.Issue], title: String? = nil, explanation: String? = nil) {
        guard canRepair, let first = issues.first, let preview = first.preview else { return }
        let alert = NSAlert()
        alert.messageText = title ?? (issues.count == 1 ? Self.action(first.kind) + "?" : "\(Self.action(first.kind)) — all \(issues.count)?")
        alert.informativeText = explanation ?? ((issues.count == 1 ? first.path + "\n\n" : "For each:\n\n") + preview)
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: issues.count == 1 ? Self.action(first.kind) : "Apply \(issues.count) Repairs")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        repairing = true
        let settings = settings
        let index = model.healthIndex
        let duplicates = model.healthDuplicates
        Task {
            defer { repairing = false; refresh += 1 }
            let outcome: (undos: [LibraryHealth.MetadataUndo], done: Int, failure: String?)? = await model.withWatchingPaused {
                guard self.settings.basePath == settings.basePath, model.working.isEmpty,
                      model.activeDocumentActions.isEmpty, model.reading.isEmpty else { return nil }
                // Each repair rescans the archive, so they run off the main thread
                return await Task.detached(priority: .userInitiated) {
                    var undos: [LibraryHealth.MetadataUndo] = [], done = 0
                    for issue in issues {
                        do {
                            let result = try LibraryHealth.repair(issue, settings: settings, index: index, duplicates: duplicates)
                            if let undo = result.undo { undos.append(undo) }
                            done += 1
                        } catch {
                            return (undos, done, Optional(error.localizedDescription))
                        }
                    }
                    return (undos, done, String?.none)
                }.value
            }
            guard let outcome else { message = "Document work is still running. Wait, refresh, and try again."; return }
            if !outcome.undos.isEmpty {
                let undos = outcome.undos
                undoManager?.registerUndo(withTarget: model) { model in
                    MainActor.assumeIsolated {
                        for undo in undos.reversed() {
                            model.undoStep("Library Repair") { try LibraryHealth.undo(undo, settings: settings, index: index) }
                        }
                        model.documentsChanged += 1
                        model.refreshTidy()
                        model.updateSpotlight()
                    }
                }
                undoManager?.setActionName(issues.count == 1 ? Self.action(first.kind) : "Library Repairs")
            }
            model.documentsChanged += 1
            model.refreshTidy()
            model.updateSpotlight()
            message = outcome.failure.map { "Done \(outcome.done) of \(issues.count); stopped at one that needs a look: \($0)" }
                ?? (issues.count == 1 ? "Done. Refreshing the health check." : "Done, all \(outcome.done). Refreshing the health check.")
        }
    }
}

// MARK: - Tax export

/// File ▸ Export Tax Documents: a year's tax documents copied into one folder for an accountant,
/// with an index and, if wanted, a single combined PDF.
struct TaxExportSheet: View {
    let model: HomeClerkModel
    @Environment(\.dismiss) private var dismiss
    @State private var year = Calendar.current.component(.year, from: .now) - 1
    @State private var combined = true
    @State private var problem: String?
    @AppStorage(DefaultsKey.backupAcknowledged) private var backupAcknowledged = false

    private var documents: [DocumentIndex.Entry] {
        guard let taxonomy = model.taxonomy else { return [] }
        return TaxPacket.documents(model.library.documents, year: year, taxonomy: taxonomy)
    }

    var body: some View {
        let documents = documents
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Tax Documents").font(.title2.weight(.semibold))
            Picker("Tax year", selection: $year) {
                let now = Calendar.current.component(.year, from: .now)
                ForEach(Array((now - 7)...now).reversed(), id: \.self) { Text(String($0)).tag($0) }
            }
            .fixedSize()
            Text("Everything in the Taxes area, tax forms and returns, W-2s, 1099s, property tax, mortgage, and charitable donations — dated in \(String(year)), plus tax forms dated early \(String(year + 1)).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(documents) { d in
                HStack {
                    Text(FiledScreen.title(d)).lineLimit(1)
                    Spacer()
                    Text(d.facets.documentDate).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(height: 220)
            .overlay { if documents.isEmpty { Text("No tax documents for \(String(year))").foregroundStyle(.secondary) } }
            Toggle("Also combine them into one PDF", isOn: $combined)
            if let problem { Text(problem).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export \(documents.count) Document\(documents.count == 1 ? "" : "s")…") { export(documents) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(documents.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func export(_ documents: [DocumentIndex.Entry]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to put the \(year) Tax Documents folder."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let out = try TaxPacket.export(documents, year: year, to: folder, combinedPDF: combined)
            NSWorkspace.shared.activateFileViewerSelecting([out])
            dismiss()
        } catch {
            problem = "Couldn't export: \(error.localizedDescription)"
        }
    }
}

/// When nothing HomeClerk can recognize backs up its folder: once the paper's shredded, it's the
/// only copy.
private struct BackupBanner: View {
    @Binding var acknowledged: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your documents may not be backed up").font(.callout.weight(.medium))
                Text("The HomeClerk folder isn't in iCloud Drive or included in Time Machine. Once the paper's shredded, it's the only copy.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Time Machine Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")!)
            }
            Button("I Back Up Another Way") { acknowledged = true }
        }
        .padding(.horizontal, Layout.margin).padding(.vertical, 10)
        .background(.orange.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A copy's page count and file size ("3 pages · 412 KB"), read off the main thread.
private struct CopyFacts: View {
    let url: URL
    @State private var facts = " "

    var body: some View {
        Text(facts).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            .task(id: url) {
                let url = url
                facts = await Task.detached(priority: .userInitiated) { TidyScreen.size(of: url) }.value
            }
    }
}
