// Tidy Up — duplicates waiting for a decision, and filed documents past their keep period — and
// the tax-year export.

import AppKit
import HomeClerkKit
import PDFKit
import SwiftUI

extension HomeClerkModel {

    /// Documents you chose to keep past their keep period.
    var keeping: Set<String> { Set(UserDefaults.standard.stringArray(forKey: DefaultsKey.keepAnyway) ?? []) }


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
    enum Mode: String { case details, duplicates, expired, originals }
    @AppStorage(DefaultsKey.tidyMode) private var mode = Mode.duplicates
    @Environment(\.undoManager) private var undoManager
    @State private var duplicate: String?
    @State private var expiredSelection = Set<String>()
    @State private var confirmKeepAlways = false
    @State private var detailsSelection = Set<String>()
    @State private var originalsSelection = Set<String>()
    @State private var problem: String?
    @AppStorage(DefaultsKey.backupAcknowledged) private var backupAcknowledged = false
    @State private var confirmOlderCopies = false

    var body: some View {
        Page(title: "Tidy Up", subtitle: subtitle) {
            Picker("Show", selection: $mode) {
                Text("Needs Details (\(model.needsDetails.count))").tag(Mode.details)
                Text("Duplicates (\(model.duplicateItems.count))").tag(Mode.duplicates)
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
            if duplicate == nil { duplicate = model.duplicateItems.first?.id }
            // Open on a list with something in it
            let counts: [(Mode, Int)] = [(.details, model.needsDetails.count), (.duplicates, model.duplicateItems.count),
                                         (.expired, model.expiredDocuments.count)]
            if counts.first(where: { $0.0 == mode })?.1 == 0, let busy = counts.first(where: { $0.1 > 0 }) { mode = busy.0 }
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

    private var subtitle: String {
        model.tidyCount == 0 ? "Nothing to tidy" : model.tidyCount == 1 ? "1 thing to look at" : "\(model.tidyCount) things to look at"
    }

    // MARK: Duplicates

    @ViewBuilder
    private var duplicates: some View {
        if model.duplicateItems.isEmpty {
            ContentUnavailableView("No duplicates", systemImage: "doc.on.doc",
                                   description: Text("Scans HomeClerk recognizes as already filed wait here for you to confirm."))
        } else {
            let item = model.duplicateItems.first { $0.id == duplicate } ?? model.duplicateItems[0]
            HStack(spacing: 0) {
                List(model.duplicateItems, selection: $duplicate) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text("Same as \((item.originalLabel as NSString).lastPathComponent)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                    .tag(item.id)
                }
                .listStyle(.inset)
                .frame(width: 240)

                Divider()

                VStack(spacing: 0) {
                    // The two side by side, as you'd compare them on a desk
                    HStack(spacing: 1) {
                        labeled("This scan", PDFPreview(url: item.url))
                        if let original = item.original {
                            labeled("Already filed: \((item.originalLabel as NSString).deletingLastPathComponent)", PDFPreview(url: original))
                        } else {
                            ContentUnavailableView("The filed copy has moved", systemImage: "questionmark.folder",
                                                   description: Text(item.originalLabel))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    Divider()
                    HStack {
                        Text(item.why.isEmpty ? "" : "Why: \(item.why)").font(.callout).foregroundStyle(.secondary)
                        if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
                        Spacer()
                        Button("Not a Duplicate") { notADuplicate(item) }
                            .help("Moves it to Review to file as its own document")
                        Button("Move to Trash") {
                            // Its notes go too, so ⌘Z brings back the whole thing
                            let notes = [ReviewProposal.reasonURL(for: item.url), ReviewProposal.proposalURL(for: item.url)]
                                .filter { FileManager.default.fileExists(atPath: $0.path) }
                            model.moveToTrash([item.url] + notes, undoManager: undoManager)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.delete, modifiers: .command)
                    }
                    .padding(.horizontal, Layout.margin)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private func labeled(_ title: String, _ preview: PDFPreview) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                .padding(.vertical, 6)
            preview
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
