// HomeClerk ▸ Settings (⌘,). Settings live in the app's preferences and take effect on their own:
// a moment after a change, HomeClerk restarts watching with the new settings.

import AppKit
import HomeClerkKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let model: HomeClerkModel
    @State private var settings = HomeClerkSettings()
    @State private var loaded = false

    var body: some View {
        TabView {
            GeneralPane(settings: $settings, model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            AnalysisPane(settings: $settings)
                .tabItem { Label("Analysis", systemImage: "sparkles") }
            OllamaPane(settings: $settings, model: model)
                .tabItem { Label("Ollama", systemImage: "desktopcomputer") }
            FinishingPane(settings: $settings)
                .tabItem { Label("After Filing", systemImage: "checkmark.seal") }
            HouseholdPane(model: model)
                .tabItem { Label("Household", systemImage: "house") }
            RulesPane(model: model)
                .tabItem { Label("Rules", systemImage: "folder.badge.gearshape") }
            APIKeyPane(model: model)
                .tabItem { Label("API Key", systemImage: "key") }
        }
        .frame(width: 520)
        .onAppear {
            settings = model.storedSettings()
            loaded = true
        }
        .onChange(of: settings) {
            if loaded { model.apply(settings) }
        }
    }
}

private struct GeneralPane: View {
    @Binding var settings: HomeClerkSettings
    let model: HomeClerkModel
    @AppStorage(DefaultsKey.indexInSpotlight) private var spotlight = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            LabeledContent("HomeClerk folder") {
                VStack(alignment: .trailing, spacing: 6) {
                    Text((settings.basePath.path as NSString).abbreviatingWithTildeInPath)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.open(settings.basePath) }
                        Button("Move…", action: move)
                            .help("Moves the folder and everything in it somewhere else, and HomeClerk with it")
                        Button("Choose…", action: choose)
                            .help("Uses a different folder, leaving this one as it is")
                    }
                    .disabled(model.movingFolder)
                    if model.movingFolder {
                        ProgressView("Moving…").controlSize(.small)
                    }
                }
            }
            Text("Inbox, Organized, _review, _duplicates, and _originals are kept inside it, along with household.json and HomeClerk's index. Move… takes everything somewhere else — another drive, or iCloud Drive; Choose… switches to a different folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Keep a copy of each scan as it arrived (_originals)", isOn: $settings.preserveOriginals)
            Toggle("Open HomeClerk when you log in", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { HomeClerkModel.setOpenAtLogin(openAtLogin) }
            Toggle(isOn: $spotlight) {
                Text("Show filed documents in Spotlight")
                Text("Find them by vendor, person, vehicle, pet, or tag. The index stays on this Mac.")
            }
            .onChange(of: spotlight) { HomeClerkModel.shared.updateSpotlight() }
            EmailedBillsSection(inbox: settings.inboxFolder)
        }
        .formStyle(.grouped)
    }

    /// Moves the folder: choose the place and name, confirm, then HomeClerk stops watching, moves
    /// it, and carries on from there.
    private func move() {
        let source = settings.basePath
        let panel = NSSavePanel()
        panel.directoryURL = source.deletingLastPathComponent()
        panel.nameFieldStringValue = source.lastPathComponent == Legacy.folderName ? "HomeClerk" : source.lastPathComponent
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.prompt = "Move"
        panel.message = "Choose where to move your HomeClerk folder, and what to call it."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try FolderMove.check(from: source, to: destination) } catch {
            NSAlert(error: error).runModal()
            return
        }
        let confirm = NSAlert()
        confirm.messageText = "Move your HomeClerk folder to \((destination.path as NSString).abbreviatingWithTildeInPath)?"
        confirm.informativeText = "HomeClerk stops watching while it moves everything, then carries on from the new place. Reminders, the Mail script, and Spotlight follow it. On another drive it's copied and checked first, and the original goes to the Trash."
        confirm.addButton(withTitle: "Move")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await model.relocate(from: source, to: destination, moving: true)
                settings = model.storedSettings()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.basePath
        panel.prompt = "Use This Folder"
        panel.message = "Choose the folder HomeClerk keeps your documents in."
        if panel.runModal() == .OK, let url = panel.url { settings.basePath = url }
    }
}

/// Bills that arrive by email: a script for a Mail rule, which saves their PDFs into the inbox.
private struct EmailedBillsSection: View {
    let inbox: URL
    /// The inbox the installed script saves to; a different HomeClerk folder needs it installed again.
    @AppStorage(DefaultsKey.mailRuleInbox) private var installedInbox = ""
    @State private var problem: String?
    @State private var showSteps = false

    private var installed: Bool { MailRule.isInstalled() && installedInbox == inbox.path }

    var body: some View {
        SwiftUI.Section {
            LabeledContent {
                Button(installed ? "Reinstall" : MailRule.isInstalled() ? "Update for This Folder" : "Set Up Mail…", action: install)
            } label: {
                Text("Emailed bills")
                Text(installed ? "Mail can send PDF attachments to HomeClerk. Choose which messages with a rule in Mail."
                     : "File PDFs that arrive by email, using a rule in Mail.")
            }
            if installed {
                Button("How to Set Up the Rule") { showSteps = true }
                    .buttonStyle(.link)
            }
            if let problem { Text(problem).foregroundStyle(.red) }
        }
        .sheet(isPresented: $showSteps) { MailRuleSteps() }
    }

    private func install() {
        do {
            try MailRule.install(inbox: inbox)
            installedInbox = inbox.path
            problem = nil
            showSteps = true
        } catch {
            problem = "Couldn't install the Mail script: \(error.localizedDescription)"
        }
    }
}

/// What to do in Mail, once the script is in place.
private struct MailRuleSteps: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Up a Mail Rule").font(.title2.weight(.semibold))
            Text("HomeClerk put a script named “\((MailRule.installedName() ?? MailRule.scriptName.replacingOccurrences(of: ".scpt", with: "")))” where Mail can use it. Now tell Mail which messages to send:")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. In Mail, choose Mail ▸ Settings, then click Rules.")
                Text("2. Click Add Rule and name it, say “Bills to HomeClerk.”")
                Text("3. Set the conditions: for example, From contains your utility’s or bank’s address. Add one condition per sender, and choose “any” at the top.")
                Text("4. Under Perform the following actions, choose Run AppleScript, then “\((MailRule.installedName() ?? MailRule.scriptName.replacingOccurrences(of: ".scpt", with: "")))”.")
                Text("5. Click OK. When Mail asks about messages already in your mailboxes, click Don’t Apply unless you want those filed too.")
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("From then on, PDFs attached to matching messages land in HomeClerk’s inbox and are filed like scans. Messages without a PDF are left alone.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Mail") {
                    if let mail = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") {
                        NSWorkspace.shared.openApplication(at: mail, configuration: .init())
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct AnalysisPane: View {
    @Binding var settings: HomeClerkSettings

    var body: some View {
        Form {
            Picker("Read documents with", selection: $settings.aiProvider) {
                // The policy is enforced by the analyzer factory, including manual re-analysis.
                Text("Claude").tag(AIProvider.claude)
                Text("Ollama (configured server)").tag(AIProvider.ollama)
                Text("Apple Intelligence").tag(AIProvider.apple)
            }
            Picker("If that fails, use", selection: $settings.fallbackProvider) {
                Text("Nothing — send to Review").tag(AIProvider?.none)
                ForEach(AIProvider.allCases.filter { $0 != settings.aiProvider }) { Text($0.rawValue).tag(Optional($0)) }
            }
            Toggle("Use local readers only", isOn: $settings.localReadersOnly)
            Text("Allows Apple on-device and loopback Ollama; blocks cloud readers, remote servers, cloud-named Ollama models, and redirects. A local Ollama server can still forward data. Enabling restarts watching immediately; requests already sent cannot be recalled.")
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
            LabeledContent("Claude spending limit") {
                HStack(spacing: 6) {
                    TextField("Limit", value: $settings.claudeMonthlyLimit, format: .currency(code: "USD"))
                        .labelsHidden()
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                    Text("a month").foregroundStyle(.secondary)
                }
            }
            Text(settings.claudeMonthlyLimit > 0
                 ? "Once a month's estimated cost reaches it, the fallback reads documents until the next month."
                 : "$0 means no limit.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Claude model", selection: $settings.claudeModel) {
                Text("Sonnet 5.5 — about 2¢ a document").tag("claude-sonnet-5-5")
                Text("Opus 5.5 — most capable, about 4¢ a document").tag("claude-opus-5-5")
            }
            Picker("Apple model", selection: $settings.appleModel) {
                Text("On this Mac").tag("on-device")
                Text("Private Cloud Compute").tag("private-cloud")
            }

            SwiftUI.Section {
                ConfidenceSlider(title: "File when at least", value: $settings.minConfidenceThreshold)
                ConfidenceSlider(title: "…or, from the fallback, at least", value: $settings.fallbackMinConfidence)
            } footer: {
                Text("Below this, a scan goes to Review with the model's proposal instead of being filed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ConfidenceSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: 0.5...0.95, step: 0.05)
                Text("\(Int((value * 100).rounded()))% sure").monospacedDigit().frame(width: 70, alignment: .trailing)
            }
        }
    }
}

private struct OllamaPane: View {
    @Binding var settings: HomeClerkSettings
    let model: HomeClerkModel
    @State private var address = ""
    @State private var other = ""

    private var memory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// Downloaded models, then recommended ones not downloaded yet.
    private var names: [String] {
        let installed = model.ollamaModels?.map(\.name) ?? []
        return installed + OllamaCatalog.recommended.map(\.name).filter { !installed.contains($0) }
    }

    var body: some View {
        Form {
            SwiftUI.Section {
                ForEach(names, id: \.self) { name in
                    OllamaModelRow(model: model, name: name,
                                   installed: model.ollamaModels?.first { $0.name == name },
                                   recommended: OllamaCatalog.recommended.first { $0.name == name },
                                   isSelected: OllamaMonitor.hasModel([name], settings.ollamaModel),
                                   isSuggested: name == OllamaCatalog.recommendation(memory: memory).name,
                                   choose: { settings.ollamaModel = name })
                    .accessibilityAddTraits(OllamaMonitor.hasModel([name], settings.ollamaModel) ? .isSelected : [])
                }
                LabeledContent("Another model") {
                    TextField("Another model", text: $other, prompt: Text("name:tag"))
                        .labelsHidden()
                        .onSubmit { if !other.isEmpty { settings.ollamaModel = other } }
                }
            } header: {
                Text("Model")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if model.ollamaModels == nil {
                        HStack {
                            Text("Ollama isn't running, so downloaded models can't be listed.")
                            Button("Start Ollama") { model.startOllama() }.controlSize(.small)
                        }
                    }
                    if let problem = model.downloadProblem { Text(problem).foregroundStyle(.red) }
                    Text("This Mac has \(OllamaModelRow.gigabytes(Int64(memory))) of memory. Speed and accuracy are measured on your documents once HomeClerk has used a model; until then they're typical figures.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            SwiftUI.Section {
                Picker("Unload the model when idle for", selection: $settings.ollamaUnloadMinutes) {
                    Text("1 minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("Never").tag(-1)
                }
                LabeledContent("Now") {
                    HStack {
                        Text(loadedStatus).foregroundStyle(.secondary)
                        if let loaded = model.ollamaLoaded, !loaded.isEmpty {
                            Button("Unload Now") { Task { for m in loaded { await model.unloadOllamaModel(m.name) } } }
                                .controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("Memory")
            } footer: {
                Text("A model takes several gigabytes while it's loaded. Each document restarts the clock, so a stack of scans keeps it ready, and it frees the memory once HomeClerk has been idle that long — even with HomeClerk left open.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SwiftUI.Section {
                TextField("Server", text: $address, prompt: Text("http://localhost:11434"))
                    .onSubmit(applyAddress)
                    .onChange(of: address) { applyAddress() }
                Text(settings.analysisDestination(for: .ollama))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let warning = settings.ollamaTransportWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Start Ollama automatically when it's needed", isOn: Binding(
                    get: { model.autoStartOllama }, set: { model.autoStartOllama = $0 }))
            } footer: {
                Text("HomeClerk starts `ollama serve` only while the app is open, and stops it when you quit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .onAppear {
            address = settings.ollamaBaseURL.absoluteString
            if !names.contains(where: { OllamaMonitor.hasModel([$0], settings.ollamaModel) }) { other = settings.ollamaModel }
        }
        .task {
            // Keep the list current while the pane is open (Ollama started, a download finished)
            while !Task.isCancelled {
                await model.refreshOllamaModels()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// "qwen3-vl:8b-instruct (5.8 GB) — unloads in about 4 min", or that nothing is loaded.
    private var loadedStatus: String {
        guard let loaded = model.ollamaLoaded else { return "Ollama isn't running" }
        guard !loaded.isEmpty else { return "No model in memory" }
        return loaded.map { m in
            let size = m.bytes > 0 ? " (\(OllamaModelRow.gigabytes(m.bytes)))" : ""
            let when = m.unloadsAt.map { date -> String in
                let minutes = max(1, Int((date.timeIntervalSinceNow / 60).rounded(.up)))
                return " — unloads in about \(minutes) min"
            } ?? " — kept loaded"
            return m.name + size + when
        }.joined(separator: "; ")
    }

    private func applyAddress() {
        if let url = URL(string: address), url.scheme == "http" || url.scheme == "https", url.host() != nil {
            settings.ollamaBaseURL = url
        }
    }
}

private struct FinishingPane: View {
    @Binding var settings: HomeClerkSettings
    @AppStorage(DefaultsKey.weeklyDigest) private var weeklyDigest = true
    @AppStorage(DefaultsKey.dueSoonNotices) private var dueSoon = true

    var body: some View {
        Form {
            Toggle("On Mondays, say what's due or expiring that week", isOn: $weeklyDigest)
            Toggle(isOn: $dueSoon) {
                Text("The day before a bill is due, say so")
                Text(settings.createReminders ? "Reminders already does this while it's on." : "With a Mark as Paid button.")
            }
            .disabled(settings.createReminders)
            Toggle(isOn: $settings.makeSearchable) {
                Text("Make scans searchable (adds a text layer)")
                Text("Rewrites image-only pages. The original bytes are always kept: in _originals when HomeClerk keeps a copy of each scan, otherwise in a hidden .homeclerk-pdf-originals folder beside the changed PDF. Forms and signature fields are left unchanged; other PDF structure may change. These copies are never automatically cleared.")
            }
            Toggle("Tag documents in Finder", isOn: $settings.applyFinderTags)
            Toggle("Add reminders for due dates and expirations", isOn: $settings.createReminders)
            if settings.createReminders {
                TextField("Reminders list", text: $settings.remindersList)
                Stepper("Remind \(settings.expirationReminderLeadDays) days before something expires",
                        value: $settings.expirationReminderLeadDays, in: 1...180)
            }
        }
        .formStyle(.grouped)
    }
}

private struct APIKeyPane: View {
    let model: HomeClerkModel
    @State private var key = ""
    @State private var hasKey = false
    @State private var message: String?

    var body: some View {
        Form {
            LabeledContent("Anthropic API key") {
                Text(hasKey ? "Stored in your Keychain" : "Not set").foregroundStyle(hasKey ? .green : .secondary)
            }
            HStack {
                SecureField("Paste a new key", text: $key, prompt: Text("sk-ant-…"))
                Button("Store") {
                    if Keychain.storeAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        key = ""
                        message = "Stored. HomeClerk uses it for the next scan."
                        model.scheduleRestart()   // the analyzer reads the key when watching starts
                    } else {
                        message = "That doesn't look like an Anthropic API key."
                    }
                    hasKey = Keychain.readAPIKey() != nil
                }
                .disabled(key.isEmpty)
            }
            if hasKey {
                Button("Remove Key", role: .destructive) {
                    Keychain.deleteAPIKey()
                    hasKey = Keychain.readAPIKey() != nil
                    model.scheduleRestart()
                    message = hasKey ? "Couldn't remove it." : "Removed."
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Text("Only Claude needs a key. It's kept in the macOS Keychain, never in a file.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { hasKey = Keychain.readAPIKey() != nil }
    }
}
