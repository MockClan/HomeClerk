import Foundation

/// Moving the HomeClerk folder somewhere else — another name, another drive, iCloud Drive. The
/// Library stores paths relative to the folder, so the documents come along as they are; what
/// points at the folder from outside (settings, the Mail script, reminders) is updated by the app.
public enum FolderMove {
    public struct Problem: Error, LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Whether `folder` looks like a HomeClerk folder — what Locate… expects to be shown.
    public static func looksLikeHomeClerkFolder(_ folder: URL) -> Bool {
        let fm = FileManager.default
        return [DocumentIndex.fileName, "Organized", "Inbox"].contains {
            fm.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    /// Refuses a move that can't work, before anything is touched.
    public static func check(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let from = source.standardizedFileURL.resolvingSymlinksInPath().path
        let to = destination.standardizedFileURL.path
        guard fm.fileExists(atPath: source.path) else { throw Problem("The HomeClerk folder isn't at \(source.path).") }
        guard to != from else { throw Problem("That's where the folder already is.") }
        guard !(to + "/").hasPrefix(from + "/") else { throw Problem("The folder can't go inside itself.") }
        guard !fm.fileExists(atPath: destination.path) else {
            throw Problem("Something named “\(destination.lastPathComponent)” is already there. Choose another name or place.")
        }
        guard fm.fileExists(atPath: destination.deletingLastPathComponent().path) else {
            throw Problem("The place to move it to doesn't exist.")
        }
    }

    /// Moves the folder. On the same drive it's a rename. To another drive it's copied, the copy
    /// checked file by file, and only then is the original moved to the Trash — never deleted.
    public static func move(from source: URL, to destination: URL) throws {
        try move(from: source, to: destination, copying: !sameVolume(source, destination.deletingLastPathComponent())) {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        }
    }

    static func move(from source: URL, to destination: URL, copying: Bool, retire: (URL) throws -> Void) throws {
        try check(from: source, to: destination)
        let fm = FileManager.default
        guard copying else {
            try fm.moveItem(at: source, to: destination)
            return
        }
        try fm.copyItem(at: source, to: destination)
        guard inventory(destination) == inventory(source) else {
            try? fm.removeItem(at: destination)
            throw Problem("The copy didn't match the original, so nothing was moved.")
        }
        try retire(source)
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let one = try? a.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject,
              let two = try? b.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject else { return false }
        return one.isEqual(two)
    }

    /// Every file under `folder`, by relative path, with its size.
    static func inventory(_ folder: URL) -> [String: Int] {
        var files: [String: Int] = [:]
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        else { return files }
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true
            else { continue }
            let path = file.standardizedFileURL.resolvingSymlinksInPath().path
            files[path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path] = values.fileSize ?? 0
        }
        return files
    }

    /// `path` moved along with the folder, or nil when it isn't in it.
    public static func rebased(_ path: String, from source: URL, to destination: URL) -> String? {
        for prefix in Set([source.standardizedFileURL.path, source.resolvingSymlinksInPath().path]) where path.hasPrefix(prefix + "/") {
            return destination.standardizedFileURL.path + path.dropFirst(prefix.count)
        }
        return nil
    }
}
