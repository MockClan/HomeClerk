// The setup assistant: a first run's few decisions — where documents live, what reads them, who's in
// the household, and how scans reach the inbox. Reopened from HomeClerk ▸ Setup Assistant.

import AppKit
import HomeClerkKit
import ServiceManagement
import SwiftUI
import UserNotifications

extension HomeClerkModel {

    /// Shows the assistant on a first run. Someone already using HomeClerk (it has filed documents
    /// or knows the household) never sees it unasked.
    func offerSetupIfNew() {
        guard !UserDefaults.standard.bool(forKey: DefaultsKey.setupComplete) else { return }
        let base = SettingsStore.app.load().basePath
        let inUse = [DocumentIndex.fileName, HouseholdProfile.fileName]
            .contains { FileManager.default.fileExists(atPath: base.appendingPathComponent($0).path) }
        if inUse { UserDefaults.standard.set(true, forKey: DefaultsKey.setupComplete) } else { showWelcome = true }
    }
}

struct WelcomeSheet: View {
    let model: HomeClerkModel
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var settings = HomeClerkSettings()
    @State private var key = ""
    @State private var keyMessage: String?
    @State private var newName = ""
    @State private var newKind: HouseholdKind = .people
    @State private var readers = Readers.detect()
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var sampleAdded = false

    private let steps = ["Welcome", "Folder", "Reading", "Household", "Scanner", "Ready"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule().fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.25)).frame(height: 4)
                }
            }
            .padding([.horizontal, .top], 24)
            .accessibilityLabel("Step \(step + 1) of \(steps.count)")

            Group {
                switch step {
                case 0: welcome
                case 1: folder
                case 2: ScrollView { reading }
                case 3: household
                case 4: scanner
                default: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)

            Divider()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step == 0 { Button("Skip Setup") { finish() } }
                Button(step == steps.count - 1 ? "Start Using HomeClerk" : "Continue") {
                    if step == steps.count - 1 { finish() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
        .onAppear {
            settings = model.storedSettings()
            // A first run on a new Mac: start from what it can actually run, not Claude without a key.
            // (Opened again later, the assistant leaves the choices already made alone.)
            if !UserDefaults.standard.bool(forKey: DefaultsKey.setupComplete) {
                (settings.aiProvider, settings.fallbackProvider) = readers.firstRunChoice
            }
        }
        .task(id: step) {
            // On the steps that show it, notice a key stored or Ollama installed meanwhile. Checking
            // the Keychain runs a separate tool, so not on every step, and not too often.
            guard step == 2 || step == steps.count - 1 else { return }
            while !Task.isCancelled {
                readers = Readers.detect()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func finish() {
        model.apply(settings)
        UserDefaults.standard.set(true, forKey: DefaultsKey.setupComplete)
        model.askForNotifications()
        dismiss()
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 12)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            heading("Welcome to HomeClerk",
                    "Scan a document, and HomeClerk reads it, names it, and files it in the right folder — bills with bills, the car's paperwork with the car. Anything it isn't sure about waits in Review for you.")
            Label("Your documents stay in a folder on this Mac.", systemImage: "lock")
            Label("Reading can happen on this Mac (free) or with Claude (a cent or two a document).", systemImage: "sparkles")
            Label("A few questions now; everything can be changed later in Settings.", systemImage: "gearshape")
        }
    }

    private var folder: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Where should documents live?",
                    "HomeClerk keeps everything in one folder: an Inbox for new scans, Organized for filed documents, and a few folders of its own. To keep them in iCloud Drive, choose a folder there.")
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(.blue).accessibilityHidden(true)
                Text((settings.basePath.path as NSString).abbreviatingWithTildeInPath).textSelection(.enabled)
                Spacer()
                Button("Choose…", action: chooseFolder)
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.basePath.deletingLastPathComponent()
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url { settings.basePath = url }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("What should read your documents?", "You can pick a backup for when the first choice isn't available.")
            Picker("Read with", selection: $settings.aiProvider) {
                Text("Claude — most accurate, about 2¢ a document").tag(AIProvider.claude)
                Text("Ollama — configured server").tag(AIProvider.ollama)
                Text("Apple Intelligence — free, built into macOS").tag(AIProvider.apple)
            }
            .pickerStyle(.radioGroup)
            switch settings.aiProvider {
            case .claude:
                Text("Claude needs an API key from console.anthropic.com. It's stored in your Keychain, not in a file.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    SecureField("API key", text: $key, prompt: Text(Keychain.readAPIKey() == nil ? "sk-ant-…" : "Already stored — paste to replace"))
                    Button("Store") {
                        keyMessage = Keychain.storeAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
                            ? "Stored in your Keychain." : "That doesn't look like an Anthropic API key."
                        key = ""
                    }
                    .disabled(key.isEmpty)
                }
                if let keyMessage { Text(keyMessage).font(.callout).foregroundStyle(.secondary) }
            case .ollama:
                ollamaSetup
            case .apple:
                if readers.appleIntelligence {
                    Label("Apple Intelligence is ready on this Mac.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("Apple Intelligence needs macOS 27 on Apple silicon, with Apple Intelligence turned on in System Settings.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open Apple Intelligence Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                    }
                }
            }
            Picker("If that isn't available", selection: $settings.fallbackProvider) {
                Text("Send scans to Review").tag(AIProvider?.none)
                ForEach(AIProvider.allCases.filter { $0 != settings.aiProvider }) { Text($0.rawValue).tag(Optional($0)) }
            }
            .fixedSize()
            Toggle("Use local readers only", isOn: $settings.localReadersOnly)
            Text("Allows Apple on-device and loopback Ollama. Cloud readers and remote Ollama are blocked, including fallback and manual re-analysis. A local server can still forward data; use a trusted local model.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(settings.analysisPrivacySummary)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if (settings.aiProvider == .ollama || settings.fallbackProvider == .ollama),
               let warning = settings.ollamaTransportWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Ollama in three steps: installed, running, and the suggested model downloaded.
    @ViewBuilder
    private var ollamaSetup: some View {
        let suggested = OllamaCatalog.recommendation(memory: ProcessInfo.processInfo.physicalMemory)
        let downloaded = model.ollamaModels?.contains { OllamaMonitor.hasModel([$0.name], suggested.name) } ?? false
        VStack(alignment: .leading, spacing: 8) {
            step(readers.ollamaInstalled, "Install Ollama") {
                Button("Get Ollama…") { NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!) }
            }
            step(model.ollamaModels != nil, "Start Ollama") {
                Button("Start") { model.startOllama() }.disabled(!readers.ollamaInstalled)
            }
            step(downloaded, "Download \(suggested.name) (\(OllamaModelRow.gigabytes(suggested.sizeBytes)), suggested for this Mac)") {
                if let state = model.downloads[suggested.name] {
                    if let progress = state.progress { ProgressView(value: progress).frame(width: 120) } else { ProgressView().controlSize(.small) }
                } else {
                    Button("Download") {
                        settings.ollamaModel = suggested.name
                        model.download(suggested.name)
                    }
                    .disabled(model.ollamaModels == nil)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await model.refreshOllamaModels()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func step<Action: View>(_ done: Bool, _ title: String, @ViewBuilder action: () -> Action) -> some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Color.green : Color.secondary)
                .accessibilityLabel(done ? "Done" : "To do")
            Text(title).foregroundStyle(done ? .secondary : .primary)
            Spacer()
            if !done { action() }
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Ready", "HomeClerk watches the Inbox from the menu bar, even with this window closed.")
            if let problem = readers.problem(settings) {
                Label(problem + " Scans will wait in Review until something can read them.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Try it with a sample").font(.headline)
                    Text(settings.aiProvider == .claude ? "A made-up electric bill goes into the Inbox (about 2¢ to read)."
                         : "A made-up electric bill goes into the Inbox.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(sampleAdded ? "Added" : "Add Sample") {
                    model.apply(settings)   // read it with the choices made here
                    model.addToInbox(data: SampleDocument.pdf(), named: "Sample electric bill.pdf")
                    sampleAdded = true
                }
                .disabled(sampleAdded)
            }
            Toggle("Open HomeClerk when you log in", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { HomeClerkModel.setOpenAtLogin(openAtLogin) }
            Text("You can change anything here later in Settings, or run this again from HomeClerk ▸ Setup Assistant.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var household: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Who's in the household?",
                    "Names help HomeClerk file a vaccination record under the right pet or a registration under the right car. Add a few now, or let HomeClerk ask as it meets them.")
            HStack {
                Picker("Kind", selection: $newKind) {
                    ForEach([HouseholdKind.people, .pets, .vehicles], id: \.self) { Text($0.singular.capitalized).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                TextField("Name", text: $newName, prompt: Text(newKind == .vehicles ? "2021 Toyota RAV4" : "Name"))
                    .onSubmit(addName)
                Button("Add", action: addName).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            let names = [HouseholdKind.people, .pets, .vehicles].flatMap { kind in
                model.household.names(kind).map { (kind, $0) }
            }
            if names.isEmpty {
                Text("No one yet.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(names, id: \.1) { kind, name in
                            Label(FinishingPlan.readable(name),
                                  systemImage: kind == .pets ? "pawprint" : kind == .vehicles ? "car" : "person")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Saved in the folder chosen in this assistant, which HomeClerk may not be using yet.
    private func addName() {
        let name = newName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
        guard !name.isEmpty else { return }
        let url = settings.householdProfilePath
        var profile = (try? HouseholdProfile.loadOrEmpty(from: url)) ?? .empty
        profile.add(name, kind: newKind)
        do {
            try profile.save(to: url)
        } catch {
            model.record(.problem, "household.json", "Couldn't save \(name): \(error.localizedDescription)", nil)
        }
        model.household = profile
        model.householdLoadedFrom = nil   // reread once HomeClerk is using that folder
        newName = ""
    }

    private var scanner: some View {
        let inbox = settings.inboxFolder
        return VStack(alignment: .leading, spacing: 12) {
            heading("Send scans to the Inbox",
                    "Set your scanner's app to save PDFs into this folder. HomeClerk notices each one within a few seconds.")
            HStack {
                Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(.blue).accessibilityHidden(true)
                Text((inbox.path as NSString).abbreviatingWithTildeInPath).textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(inbox.path, forType: .string)
                }
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([inbox])
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            Label("Image Capture: choose your scanner, set Format to PDF and Scan To to this folder.", systemImage: "scanner")
            Label("A scanner's own app (Epson, Canon, Fujitsu…): set its save folder to this one.", systemImage: "gearshape.2")
            Label("Or drag PDFs onto the HomeClerk window, or its Dock icon.", systemImage: "hand.draw")
        }
    }
}

extension HomeClerkModel {
    /// Asks to show notifications — after setup, when the request makes sense, rather than at the
    /// very first launch.
    func askForNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Opening at login is opt-in (Settings ▸ General, or the assistant's last step).
    static func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            HomeClerkModel.shared.errorDetails = "Couldn't change Open at Login: \(error.localizedDescription)"
        }
    }

    /// Why nothing configured can read a scan, if that's so.
    var readinessProblem: String? {
        guard let settings = currentSettings else { return nil }
        return readers.problem(settings)
    }
}

/// A made-up electric bill for trying HomeClerk out, dated today.
enum SampleDocument {
    static func pdf() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        let today = Date.now
        let due = Calendar.current.date(byAdding: .day, value: 21, to: today) ?? today
        let lines: [(String, CGFloat)] = [
            ("Example Power Company", 22), ("Electric Service Statement", 15), ("", 12),
            ("Account 0000-0000-00   (sample — not a real account)", 12),
            ("Statement date: \(today.formatted(date: .long, time: .omitted))", 12),
            ("Service period: 30 days", 12), ("", 12),
            ("Electricity used: 512 kWh", 12), ("Amount due: $64.18", 14),
            ("Please pay by \(due.formatted(date: .long, time: .omitted))", 12), ("", 12),
            ("This is a sample document from HomeClerk's Setup Assistant.", 10)
        ]
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        var y: CGFloat = 720
        for (text, size) in lines {
            (text as NSString).draw(at: CGPoint(x: 72, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size)])
            y -= size + 12
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
