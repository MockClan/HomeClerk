import Foundation
import os

/// Folders of personal documents are kept private to this account.
public enum PrivateFolder {
    private static let log = Logger(subsystem: "com.mockclan.homeclerk", category: "folders")

    /// Creates the folder if needed and removes any access for other accounts (mode 700).
    public static func secure(_ folder: URL) throws {
        try FileOrganizer.requireInside(folder, folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        if mode & 0o077 != 0 {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode & 0o700 | 0o700)], ofItemAtPath: folder.path)
            log.info("Restricted a HomeClerk folder to this account")
        }
    }
}
