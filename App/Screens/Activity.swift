// Activity: what HomeClerk is doing and has done, with the banners that explain a problem.

import AppKit
import CoreSpotlight
import HomeClerkKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct ContentView: View {
    let model: HomeClerkModel

    var body: some View {
        Page(title: "Activity", subtitle: model.statusText) {
            VStack(spacing: 0) {
                if case .failed(let message) = model.state {
                    ErrorBanner(model: model, message: message)
                        .padding(.horizontal, Layout.margin)
                        .padding(.top, 14)
                }

                if let problem = model.taxonomyProblem {
                    TaxonomyProblemBanner(problem: problem)
                        .padding(.horizontal, Layout.margin)
                        .padding(.top, 14)
                }

                if let problem = model.readinessProblem, model.state == .watching {
                    ReadinessBanner(model: model, problem: problem)
                        .padding(.horizontal, Layout.margin)
                        .padding(.top, 14)
                }

                if let limit = model.currentSettings?.claudeMonthlyLimit, limit > 0, model.claudeSpent >= Decimal(limit) {
                    BudgetBanner(spent: model.claudeSpent, limit: Decimal(limit))
                        .padding(.horizontal, Layout.margin)
                        .padding(.top, 14)
                }

                if let ollama = model.ollama, ollama.status != "ready", model.state == .watching {
                    OllamaBanner(model: model, ollama: ollama)
                        .padding(.horizontal, Layout.margin)
                        .padding(.top, 14)
                }

                Summary(model: model)
                    .padding(.horizontal, Layout.margin)
                    .padding(.vertical, 10)

                if !model.finishingRepairs.isEmpty || model.finishingProblem != nil {
                    HStack {
                        Label(model.finishingProblem == nil ? "\(model.finishingRepairs.count) filed documents need finishing" : "Finishing repair history needs attention",
                              systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button("Review Repairs") { model.showFinishingRepairs = true }
                    }
                    .font(.callout).foregroundStyle(.orange)
                    .padding(.horizontal, Layout.margin).padding(.bottom, 10)
                }

                Divider()

                if !model.working.isEmpty {
                    WorkingList(model: model)
                    Divider()
                }

                ActivityList(model: model)
            }
        }
        .animation(.snappy, value: model.activity.count)
        .animation(.snappy, value: model.working.count)
        .animation(.default, value: model.ollama)
        .animation(.default, value: model.state)
        .onAppear { model.refreshFinishing() }
        .sheet(isPresented: Binding(get: { model.showFinishingRepairs }, set: { model.showFinishingRepairs = $0 })) {
            FinishingRepairsSheet(model: model)
        }
    }

}

struct FinishingRepairsSheet: View {
    let model: HomeClerkModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finish Filed Documents").font(.title2.weight(.semibold))
            Text("These documents are filed. Retry runs failed steps that are enabled in Settings, using the current document details. Finder tags are reapplied after searchable-text repair. Disabled steps remain here until enabled and retried.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem = model.finishingProblem {
                Text(problem).foregroundStyle(.orange).textSelection(.enabled)
            }
            if model.finishingRepairs.isEmpty && model.finishingProblem == nil {
                ContentUnavailableView("No finishing repairs", systemImage: "checkmark.circle")
            } else {
                List(model.finishingRepairs) { repair in
                    VStack(alignment: .leading, spacing: 6) {
                        Text((repair.path as NSString).lastPathComponent).fontWeight(.medium)
                        ForEach(repair.failures, id: \.step) { failure in
                            Text("\(failure.step.title): \(failure.detail)")
                                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        HStack {
                            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: repair.path)) }
                            Button("Show Details") { model.focusedDocument = repair.path; model.section = .filed; dismiss() }
                            Spacer()
                            Button(model.repairingDocuments.contains(repair.documentID) ? "Retrying…" : "Retry") {
                                model.retryFinishing(repair.documentID)
                            }
                            .disabled(model.repairingDocuments.contains(repair.documentID) || !model.canRetryFinishing(repair))
                            .help("Enable failed steps in Settings ▸ After Filing to retry them. Wait for any restart to finish first.")
                        }
                    }.padding(.vertical, 6)
                }
            }
            HStack {
                Button("Refresh") { model.refreshFinishing() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 640, height: 480)
    }
}

/// This session's counts in one quiet line, as Mail and Finder show theirs.
struct Summary: View {
    let model: HomeClerkModel

    /// Today's outcomes of a kind, from Activity (which includes earlier sessions today).
    private func today(_ kind: Activity.Kind) -> Int {
        model.activity.filter { $0.kind == kind && Calendar.current.isDateInToday($0.time) }.count
    }

    var body: some View {
        HStack(spacing: 16) {
            Label("\(today(.filed)) filed today", systemImage: "checkmark.circle")
            Button { model.section = .review } label: {
                Label("\(model.needsReview) need\(model.needsReview == 1 ? "s" : "") review", systemImage: "exclamationmark.bubble")
                    .foregroundStyle(model.needsReview > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help("Show Review (⌘2)")
            let duplicates = today(.duplicate)
            Label("\(duplicates) duplicate\(duplicates == 1 ? "" : "s") today", systemImage: "doc.on.doc")
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .contentTransition(.numericText())
    }
}

struct ActivityList: View {
    let model: HomeClerkModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        if model.activity.isEmpty {
            ContentUnavailableView {
                Label("Ready for scans", systemImage: "doc.viewfinder")
            } description: {
                Text("Scan into your inbox, or drop PDFs here.\nEach document shows up as it's filed.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(days, id: \.title) { day in
                    SwiftUI.Section(day.title) {
                        ForEach(day.items) { item in
                            ActivityRow(item: item)
                                .listRowSeparator(.visible)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { open(item) }
                                .contextMenu {
                                    if item.kind == .filed, let path = item.path {
                                        Button("Show Details") {
                                            model.focusedDocument = path
                                            model.section = .filed
                                        }
                                        Button("Send Back to Review") { sendBack(path) }
                                            .help("Takes it out of its folder to file again")
                                        Divider()
                                    }
                                    if let path = item.path {
                                        Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                                        Button("Reveal in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                        }
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    /// A misfile caught right away: back to Review with what HomeClerk read, to file again. ⌘Z undoes it.
    private func sendBack(_ path: String) {
        guard let actions = model.reviewActions,
              let entry = model.library.documents.first(where: { $0.path == path }) else { return }
        do {
            let returned = try actions.returnToReview(entry)
            undoManager?.registerUndo(withTarget: model) { model in
                MainActor.assumeIsolated {
                    model.undoStep("Send Back to Review") { try model.reviewActions?.undo(returned) }
                    model.refreshReview()
                    model.documentsChanged += 1
                }
            }
            undoManager?.setActionName("Send Back to Review")
            model.refreshReview()
            model.documentsChanged += 1
            model.section = .review
        } catch {
            model.record(.problem, (path as NSString).lastPathComponent, "Couldn't send it back: \(error.localizedDescription)", nil)
        }
    }

    /// Today, Yesterday, then each earlier day, as Activity groups what happened.
    private var days: [(title: String, items: [Activity])] {
        var out: [(title: String, items: [Activity])] = []
        let calendar = Calendar.current
        for item in model.activity {
            let title = calendar.isDateInToday(item.time) ? "Today" : calendar.isDateInYesterday(item.time) ? "Yesterday"
                : item.time.formatted(.dateTime.weekday(.wide).month(.wide).day())
            if out.last?.title == title { out[out.count - 1].items.append(item) } else { out.append((title, [item])) }
        }
        return out
    }

    private func open(_ item: Activity) {
        guard let path = item.path, FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

struct ActivityRow: View {
    let item: Activity

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            if let engine = item.engine { EngineBadge(engine: engine, fallback: item.fallback) }

            Text(item.time, style: .time)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        // VoiceOver reads the row as one item: "Filed: name, folder, by Claude, 3:41 PM"
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kindName): \(item.title)")
        .accessibilityValue([item.detail, item.engine.map { "by \(engineShortName($0))\(item.fallback ? ", as fallback" : "")" },
                             item.time.formatted(date: .omitted, time: .shortened)].compactMap { $0 }.joined(separator: ", "))
    }

    private var kindName: String {
        switch item.kind {
        case .filed: "Filed"
        case .review: "Needs review"
        case .duplicate: "Duplicate"
        case .added: "Added"
        case .problem: "Problem"
        }
    }

    private var symbol: String {
        switch item.kind {
        case .filed: "checkmark"
        case .review: "exclamationmark"
        case .duplicate: "doc.on.doc"
        case .added: "arrow.down"
        case .problem: "xmark"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .filed: .green
        case .review: .orange
        case .duplicate: .blue
        case .added: .secondary
        case .problem: .red
        }
    }
}

/// Documents HomeClerk is working on right now, each with a spinner and its current step.
struct WorkingList: View {
    let model: HomeClerkModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Working on")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(model.working) { item in
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(item.stageText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                            .animation(.default, value: item.stage)
                    }
                    Spacer(minLength: 8)
                    // Elapsed time, so a slow local model visibly isn't stuck
                    Text(item.started, style: .timer)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Working on \(item.name)")
                .accessibilityValue(item.stageText)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.05))
    }
}

/// Shown while Ollama is in use but not running, or running without the configured model.
struct OllamaBanner: View {
    let model: HomeClerkModel
    let ollama: OllamaInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(.medium))
                    Text(model.ollamaProblem ?? detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        // A line limit rather than fixedSize: inside the split view, fixedSize text
                        // reports its narrowest, tallest size and the window lays out twice its height
                        .lineLimit(4)
                }
                Spacer()
                if ollama.status == "stopped" {
                    if model.ollamaStarting {
                        ProgressView().controlSize(.small)
                        Text("Starting…").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Button("Start Ollama") { model.startOllama() }
                    }
                } else if let state = model.downloads[ollama.model] {
                    if let progress = state.progress {
                        ProgressView(value: progress).frame(width: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(state.status.capitalized).font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("Download") { model.download(ollama.model) }
                        .help("Downloads \(ollama.model) through Ollama")
                }
            }
            if ollama.status == "stopped" {
                Toggle("Start Ollama automatically when HomeClerk opens", isOn: Binding(
                    get: { model.autoStartOllama }, set: { model.autoStartOllama = $0 }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .padding(.leading, 26)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var title: String {
        switch ollama.status {
        case "missing-model": "Ollama doesn't have \(ollama.model)"
        default: "Ollama isn't running"
        }
    }

    private var detail: String {
        let impact = ollama.role == "fallback"
            ? "If Claude is unavailable, scans go to Review instead of falling back to it."
            : "Scans can't be analyzed until it is."
        return ollama.status == "missing-model"
            ? "Download it here, or choose another model in Settings ▸ Ollama. \(impact)"
            : "\(impact) Starting it here stops it again when you quit HomeClerk."
    }
}

/// Which engine analyzed a document: "Claude", "Ollama", or "Apple", in orange when it was the
/// fallback. Hover for the exact model.
struct EngineBadge: View {
    let engine: String
    let fallback: Bool

    var body: some View {
        Text(engineShortName(engine))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(fallback ? Color.orange : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((fallback ? Color.orange : Color.secondary).opacity(0.12), in: Capsule())
            .help(fallback ? "\(engine) (fallback; the main AI provider failed)" : engine)
            .accessibilityLabel(fallback ? "Analyzed by \(engine), as fallback" : "Analyzed by \(engine)")
    }
}

struct ErrorBanner: View {
    let model: HomeClerkModel
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).accessibilityHidden(true)
                Text(message).font(.callout.weight(.medium))
                Spacer()
                if !model.errorDetails.isEmpty {
                    Button(model.showErrorDetails ? "Hide details" : "Details") { model.showErrorDetails.toggle() }
                        .buttonStyle(.link)
                }
                Button("Try Again") { model.start() }
            }
            if model.showErrorDetails {
                ScrollView {
                    Text(model.errorDetails)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.red.opacity(0.25)))
    }
}
