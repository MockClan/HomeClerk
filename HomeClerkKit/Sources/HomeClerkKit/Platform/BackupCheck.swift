import Foundation

/// Whether the HomeClerk folder is backed up somewhere: once the paper's shredded, it's the only
/// copy. Recognizes iCloud Drive, Time Machine, and Backblaze; other backups can't be seen.
public enum BackupCheck {
    public enum Coverage: String, Equatable, Sendable {
        case iCloudDrive = "iCloud Drive", timeMachine = "Time Machine", backblaze = "Backblaze"
    }

    /// What covers `folder`; empty when nothing HomeClerk can recognize does. Runs `tmutil`, so call
    /// it off the main thread.
    public static func coverage(of folder: URL) -> [Coverage] {
        var found: [Coverage] = []
        if isInICloudDrive(folder) { found.append(.iCloudDrive) }
        if timeMachineIncludes(folder) { found.append(.timeMachine) }
        if FileManager.default.fileExists(atPath: "/Library/Backblaze.bzpkg") { found.append(.backblaze) }
        return found
    }

    /// In iCloud Drive itself, or in Desktop or Documents while those sync to iCloud.
    static func isInICloudDrive(_ folder: URL) -> Bool {
        if folder.standardizedFileURL.path.contains("/Library/Mobile Documents/") { return true }
        return FileManager.default.isUbiquitousItem(at: folder)
    }

    /// Time Machine has a backup disk set up, and the folder isn't excluded from it.
    static func timeMachineIncludes(_ folder: URL) -> Bool {
        guard let destinations = run("/usr/bin/tmutil", ["destinationinfo"]), destinations.contains("Name") else { return false }
        return run("/usr/bin/tmutil", ["isexcluded", folder.path])?.hasPrefix("[Included]") ?? false
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
