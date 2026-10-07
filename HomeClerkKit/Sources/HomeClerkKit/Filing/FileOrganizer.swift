import Darwin
import Foundation

/// Moves PDFs into folders under Organized, resolving name conflicts with _2, _3, ….
public struct FileOrganizer: Sendable {
    public let outbox: URL

    public init(outbox: URL) { self.outbox = outbox }

    public struct OutsideOrganized: LocalizedError, CustomStringConvertible {
        public let description = "This path is outside its managed folder or contains a symbolic link"
        public var errorDescription: String? { description }
    }

    /// Moves `source` to `folder` under Organized as `filename`; returns where it ended up.
    @discardableResult
    public func organize(_ source: URL, folder: String, filename: String) throws -> URL {
        let destination = try destination(folder: folder, filename: filename)
        try Self.requireInside(destination, outbox)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    /// Resolves the name without moving the source, for a recoverable filing operation.
    public func destination(folder: String, filename: String, reserved: Set<String> = []) throws -> URL {
        let folderURL = outbox.appendingPathComponent(Self.sanitizeFolder(folder), isDirectory: true)
        // Folder names come from taxonomy.json or the model's area; never let one climb out of Organized
        guard Self.isInside(folderURL, outbox) else { throw OutsideOrganized() }
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        var name = Self.sanitizeFile(filename)
        // ".pdf" alone has no name (NSString would treat it as a hidden file with no extension)
        let stem = name.lowercased().hasSuffix(".pdf") ? String(name.dropLast(4)) : (name as NSString).deletingPathExtension
        if stem.trimmingCharacters(in: .whitespaces).isEmpty {
            name = "document_\(Self.timestamp()).pdf"
        } else if !name.lowercased().hasSuffix(".pdf") {
            name += ".pdf"
        }
        let wanted = folderURL.appendingPathComponent(name)
        if !reserved.contains(wanted.path), !FileManager.default.fileExists(atPath: wanted.path) { return wanted }
        let outputStem = wanted.deletingPathExtension().lastPathComponent
        for n in 2... {
            let candidate = folderURL.appendingPathComponent("\(outputStem)_\(n).pdf")
            if !reserved.contains(candidate.path), !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        fatalError("unreachable")
    }

    /// `url`, or the first of name_2, name_3, … that doesn't exist yet.
    public static func unique(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        for n in 2... {
            let candidate = folder.appendingPathComponent("\(stem)_\(n)\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        fatalError("unreachable")
    }

    /// One folder name: spaces, hyphens, and parentheses stay; path separators become hyphens and
    /// leading dots go, so a name can't reach outside Organized or make a hidden folder.
    static func sanitizeFolder(_ name: String) -> String {
        let flat = name.replacingOccurrences(of: "\0", with: "").replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = String(flat.drop { $0 == "." }).trimmingCharacters(in: .whitespaces)
        return visible.isEmpty ? "Uncategorized" : visible
    }

    /// Managed paths must resolve inside their root, with no symlinks at the root or beneath it.
    /// Ancestor aliases (such as macOS /var → /private/var) are allowed. Missing descendants are
    /// allowed so this also checks destinations before creating folders. Traversal is rejected.
    public static func isInside(_ url: URL, _ folder: URL) -> Bool {
        guard url.isFileURL, folder.isFileURL,
              !url.pathComponents.contains(".."), !folder.pathComponents.contains("..") else { return false }
        func noLink(_ url: URL) -> Bool {
            var info = stat()
            if lstat(url.path, &info) == 0 { return info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) }
            return errno == ENOENT
        }
        guard noLink(folder) else { return false }
        let base = canonicalPath(folder), path = canonicalPath(url)
        guard path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/") else { return false }
        // Enumerated URLs can use /private/var while settings use /var, so compare canonical
        // ancestors rather than requiring their textual spelling to match.
        var candidate = url.standardized
        while true {
            guard noLink(candidate) else { return false }
            if canonicalPath(candidate) == base { return true }
            guard candidate.path != "/" else { return false }
            candidate.deleteLastPathComponent()
        }
    }

    /// Foundation leaves a nonexistent path unresolved, even if an ancestor is a symlink.
    private static func canonicalPath(_ url: URL) -> String {
        var ancestor = url.standardized
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in missing.reversed() { resolved.appendPathComponent(component) }
        return resolved.standardized.path
    }

    /// A stable label even when one path uses /var and the other uses /private/var,
    /// or when a destination does not exist yet.
    static func relativePath(_ url: URL, in folder: URL) -> String? {
        guard isInside(url, folder) else { return nil }
        let path = canonicalPath(url), base = canonicalPath(folder)
        return path == base ? "" : String(path.dropFirst(base.count + (base.hasSuffix("/") ? 0 : 1)))
    }

    public static func requireInside(_ url: URL, _ folder: URL) throws {
        guard isInside(url, folder) else { throw OutsideOrganized() }
    }

    /// Characters a file name can't hold, and spaces, become underscores.
    static func sanitizeFile(_ name: String) -> String {
        String(name.map { $0 == "/" || $0 == "\0" || $0 == " " ? "_" : $0 }).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func timestamp() -> String {
        Date().formatted(Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)_\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
            timeZone: .current, calendar: .current))
    }
}
