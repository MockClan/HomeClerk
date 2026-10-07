import Foundation
import Testing
@testable import HomeClerkKit

/// Carrying over what the app left under its old name, DocuSort.
@Suite final class LegacyTests {
    let temp = TempFolder()
    private var domains: [String] = []

    /// A throwaway preferences domain, removed when the test ends.
    func defaults() -> UserDefaults {
        let name = "homeclerk-legacy-test-\(UUID().uuidString)"
        domains.append(name)
        return UserDefaults(suiteName: name)!
    }

    deinit {
        for name in domains {
            UserDefaults.standard.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(name).plist"))
        }
    }

    @Test func preferencesCarryOverOnceAndPinTheOldFolderAndList() throws {
        try FileManager.default.createDirectory(at: temp.url.appendingPathComponent("DocuSort"), withIntermediateDirectories: true)
        let new = defaults()
        new.set("Mine", forKey: "WhatsNewSeen")
        #expect(Legacy.migratePreferences(from: ["SetupComplete": true, "WhatsNewSeen": "Old"], to: new, home: temp.url))
        #expect(new.bool(forKey: "SetupComplete"))
        #expect(new.string(forKey: "WhatsNewSeen") == "Mine")   // what's already there wins
        #expect(new.string(forKey: "BasePath") == temp.url.appendingPathComponent("DocuSort").path)
        #expect(new.string(forKey: "RemindersList") == "DocuSort")
        #expect(SettingsStore(defaults: new).load(environment: [:]).basePath.lastPathComponent == "DocuSort")

        new.removeObject(forKey: "SetupComplete")
        #expect(!Legacy.migratePreferences(from: ["SetupComplete": true], to: new, home: temp.url))
        #expect(new.object(forKey: "SetupComplete") == nil)
    }

    @Test func aNewMacKeepsTheNewDefaults() {
        let new = defaults()
        #expect(!Legacy.migratePreferences(from: nil, to: new, home: temp.url))
        #expect(new.object(forKey: "BasePath") == nil && new.object(forKey: "RemindersList") == nil)
        #expect(new.bool(forKey: Legacy.migratedKey))
    }

    @Test func aChosenFolderAndListStayAsChosen() throws {
        try FileManager.default.createDirectory(at: temp.url.appendingPathComponent("DocuSort"), withIntermediateDirectories: true)
        let new = defaults()
        Legacy.migratePreferences(from: ["BasePath": "/Volumes/Archive/Paperwork", "RemindersList": "Bills"], to: new, home: temp.url)
        #expect(new.string(forKey: "BasePath") == "/Volumes/Archive/Paperwork")
        #expect(new.string(forKey: "RemindersList") == "Bills")
    }

    @Test func hiddenWorkingFoldersAreRenamedUnlessTheNewOnesExist() throws {
        let fm = FileManager.default
        for name in [".docusort-cache/analysis", ".docusort-operations/pending", ".homeclerk-cache"] {
            try fm.createDirectory(at: temp.url.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        Legacy.migrateFolder(temp.url)
        #expect(fm.fileExists(atPath: temp.url.appendingPathComponent(".homeclerk-operations/pending").path))
        #expect(!fm.fileExists(atPath: temp.url.appendingPathComponent(".docusort-operations").path))
        // Both caches exist: neither is touched
        #expect(fm.fileExists(atPath: temp.url.appendingPathComponent(".docusort-cache/analysis").path))
    }

    @Test func theOldMailScriptCountsAsInstalled() throws {
        #expect(MailRule.installedName(in: temp.url) == nil)
        try Data().write(to: temp.url.appendingPathComponent(Legacy.mailScriptName))
        #expect(MailRule.installedName(in: temp.url) == "Send PDFs to DocuSort")
        try Data().write(to: temp.url.appendingPathComponent(MailRule.scriptName))
        #expect(MailRule.installedName(in: temp.url) == "Send PDFs to HomeClerk")
    }

    @Test func theOldAppsLockKeepsBothFromWatchingOneFolder() throws {
        let legacy = temp.url.appendingPathComponent(".docusort.lock")
        let old = open(legacy.path, O_RDWR | O_CREAT, 0o600)
        defer { close(old) }
        #expect(flock(old, LOCK_EX | LOCK_NB) == 0)
        let lock = FolderLock(folder: temp.url)
        #expect(throws: FolderLock.Held.self) { try lock.acquire() }
        flock(old, LOCK_UN)
        try lock.acquire()
        // The new app now holds the old lock too
        #expect(flock(old, LOCK_EX | LOCK_NB) != 0)
        lock.release()
        #expect(flock(old, LOCK_EX | LOCK_NB) == 0)
    }
}
