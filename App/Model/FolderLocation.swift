// Where the HomeClerk folder lives, and moving it: Settings ▸ General ▸ Move…, or Locate… when the
// folder was moved in Finder. The Library stores paths relative to the folder, so the documents
// come along as they are; this updates what points at the folder from outside it.

import AppKit
import HomeClerkKit

extension HomeClerkModel {
    /// Moves the folder to `destination` (`moving`), or switches to where it's already been moved
    /// (Locate…), then carries on watching from there. A failed move leaves everything where it was.
    func relocate(from source: URL, to destination: URL, moving: Bool) async throws {
        if pipeline != nil {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                if !stop(done: { done.resume() }) { done.resume() }
            }
        }
        if moving {
            movingFolder = true
            defer { movingFolder = false }
            do {
                try await Task.detached { try FolderMove.move(from: source, to: destination) }.value
            } catch {
                start()
                throw error
            }
        }
        var settings = storedSettings()
        settings.basePath = destination
        SettingsStore.app.save(settings)
        rebaseRememberedPaths(from: source, to: destination)
        // The Mail script has the inbox's path in it; reinstall it under whatever name the rule runs
        let installed = MailRule.installedFiles()
        for name in installed { try? MailRule.install(inbox: settings.inboxFolder, named: name) }
        if !installed.isEmpty { UserDefaults.standard.set(settings.inboxFolder.path, forKey: DefaultsKey.mailRuleInbox) }
        missingFolder = nil
        start()
        documentsChanged += 1
        updateSpotlight()
        if settings.createReminders {
            let list = settings.remindersList
            Task { try? await Reminders.relink(from: source, to: destination, inList: list) }
        }
    }

    /// Paths the app remembers by full path (documents you chose to keep or leave, due-soon
    /// notices), moved along with the folder.
    private func rebaseRememberedPaths(from source: URL, to destination: URL) {
        let defaults = UserDefaults.standard
        for key in [DefaultsKey.keepAnyway, DefaultsKey.leaveAsIs] {
            guard let paths = defaults.stringArray(forKey: key) else { continue }
            defaults.set(paths.map { FolderMove.rebased($0, from: source, to: destination) ?? $0 }, forKey: key)
        }
        if let notices = defaults.stringArray(forKey: DefaultsKey.noticedDue) {
            defaults.set(notices.map { notice in
                let parts = notice.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, let moved = FolderMove.rebased(parts[0], from: source, to: destination) else { return notice }
                return moved + "|" + parts[1]
            }, forKey: DefaultsKey.noticedDue)
        }
    }

    /// Locate…: asks where the folder went and carries on from there.
    func locateMissingFolder() {
        guard let missing = missingFolder else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = missing.deletingLastPathComponent()
        panel.prompt = "Use This Folder"
        panel.message = "Show HomeClerk where your folder is now. It was at \((missing.path as NSString).abbreviatingWithTildeInPath)."
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        guard FolderMove.looksLikeHomeClerkFolder(chosen) else {
            let alert = NSAlert()
            alert.messageText = "That isn't a HomeClerk folder"
            alert.informativeText = "It has no Library (index.jsonl), Organized, or Inbox in it. Choose the folder that does."
            alert.runModal()
            return
        }
        Task { try? await relocate(from: missing, to: chosen, moving: false) }
    }

    /// Starts over with an empty folder where the old one was.
    func startNewFolder() {
        guard let missing = missingFolder else { return }
        try? FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        missingFolder = nil
        start()
    }

    /// Try Again: for a drive that wasn't connected yet.
    func retryMissingFolder() {
        missingFolder = nil
        start()
    }
}
