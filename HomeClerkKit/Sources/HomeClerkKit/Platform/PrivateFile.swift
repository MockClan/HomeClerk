import Foundation

/// Files only this account can read — household details, what's printed in documents, history,
/// paid marks. They're created that way, rather than written and then restricted, so there's no
/// moment when another account could read them.
public enum PrivateFile {
    /// Replaces `url` with `data` all at once (a reader sees the old file or the new, never half).
    public static func write(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        // rename(2) keeps the new file's permissions, where FileManager's replace can carry over the old one's
        guard rename(temp.path, url.path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Adds `data` to the end of `url`, creating it private if it doesn't exist yet.
    public static func append(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Pretty-printed JSON with sorted keys and ISO 8601 dates, so the files read well and diff cleanly.
    public static func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(value), to: url)
    }

    /// The JSON at `url`, or nil when it's missing or unreadable.
    public static func readJSON<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}
