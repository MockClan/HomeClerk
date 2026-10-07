import Foundation

/// HomeClerk was called DocuSort before 1.0. These are the names that version left on a Mac, so
/// HomeClerk can carry them over once and keep working with what's already there: the same
/// folder, Reminders list, Claude key, Mail rule, and work in progress.
public enum Legacy {
    public static let defaultsDomain = "com.mockclan.docusort"
    public static let keychainService = "DocuSort"
    public static let folderName = "DocuSort"
    public static let remindersList = "DocuSort"
    /// The app name in the marker that ties a reminder to its document.
    static let reminderMarkerApp = "DocuSort"
    /// The script a Mail rule may already run; it saves to the same inbox, so it's left in place.
    public static let mailScriptName = "Send PDFs to DocuSort.scpt"
    /// Held too while watching, so the old app (say, still opening at login) can't watch the same folder.
    static let lockName = ".docusort.lock"
    /// Hidden working folders inside the documents folder, old name and new.
    static let hiddenFolders = [(".docusort-cache", ".homeclerk-cache"), (".docusort-operations", ".homeclerk-operations")]
    /// Run logs the original version wrote into the documents folder.
    static let logPrefix = "docusort-"
    /// Where the private accuracy test set was kept.
    public static let testDataFolder = "DocuSort-TestData"
    /// Marks the preferences once carried over, so it happens only once.
    public static let migratedKey = "MigratedFromDocuSort"

    /// Copies the old preferences into `new`, once. Settings left at their old defaults are pinned
    /// where they'd otherwise change with the new name: the documents folder (when ~/DocuSort exists
    /// and ~/HomeClerk doesn't) and the Reminders list (when the old app was used). Returns whether
    /// anything was carried over.
    @discardableResult
    public static func migratePreferences(from old: [String: Any]?, to new: UserDefaults,
                                          home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard !new.bool(forKey: migratedKey) else { return false }
        defer { new.set(true, forKey: migratedKey) }
        var carried = false
        for (key, value) in old ?? [:] where new.object(forKey: key) == nil {
            new.set(value, forKey: key)
            carried = true
        }
        let oldFolder = home.appendingPathComponent(folderName), newFolder = home.appendingPathComponent("HomeClerk")
        if old?["BasePath"] == nil, new.object(forKey: "BasePath") == nil,
           FileManager.default.fileExists(atPath: oldFolder.path), !FileManager.default.fileExists(atPath: newFolder.path) {
            new.set(oldFolder.path, forKey: "BasePath")
            carried = true
        }
        if old != nil, old?["RemindersList"] == nil, new.object(forKey: "RemindersList") == nil {
            new.set(remindersList, forKey: "RemindersList")
            carried = true
        }
        return carried
    }

    /// Stores the old Keychain entry's Claude key under HomeClerk's name, when HomeClerk has none.
    /// The old entry stays, so the old app keeps working until it's deleted.
    @discardableResult
    public static func migrateAPIKey() -> Bool {
        guard Keychain.readAPIKey() == nil, let key = Keychain.readAPIKey(service: keychainService) else { return false }
        return Keychain.storeAPIKey(key)
    }

    /// Renames the hidden working folders in the documents folder — including filings still in
    /// progress, which are then recovered as usual. Leaves both alone when the new one exists.
    public static func migrateFolder(_ base: URL) {
        let fm = FileManager.default
        for (old, new) in hiddenFolders {
            let from = base.appendingPathComponent(old), to = base.appendingPathComponent(new)
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            try? fm.moveItem(at: from, to: to)
        }
    }
}
