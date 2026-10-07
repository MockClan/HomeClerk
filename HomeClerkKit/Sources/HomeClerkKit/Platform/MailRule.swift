import Foundation

/// Emailed bills: an AppleScript that a Mail rule runs, saving the PDF attachments of matching
/// messages into HomeClerk's inbox. Mail only runs scripts from its own scripts folder, so HomeClerk
/// puts it there; the rule itself (which senders, which subjects) is set up in Mail by you.
public enum MailRule {
    public static let scriptName = "Send PDFs to HomeClerk.scpt"

    /// ~/Library/Application Scripts/com.apple.mail — the folder Mail's "Run AppleScript" lists.
    public static var scriptsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Scripts/com.apple.mail", isDirectory: true)
    }

    /// The script, saving to `inbox`. Each file name starts with when it was saved, so two
    /// "statement.pdf"s don't overwrite each other.
    public static func source(inbox: URL) -> String {
        let folder = inbox.path.hasSuffix("/") ? inbox.path : inbox.path + "/"
        return """
        -- Installed by HomeClerk. Saves PDF attachments of the messages a Mail rule picks into
        -- HomeClerk's inbox, where they're read and filed like scans.
        using terms from application "Mail"
            on perform mail action with messages theMessages for rule theRule
                set inboxFolder to "\(escaped(folder))"
                repeat with theMessage in theMessages
                    repeat with theAttachment in mail attachments of theMessage
                        set fileName to name of theAttachment
                        if fileName ends with ".pdf" then
                            set stamp to do shell script "date +%Y%m%d-%H%M%S"
                            set target to inboxFolder & stamp & "-" & fileName
                            try
                                save theAttachment in POSIX file target
                            on error
                                -- Mail may not be allowed to write there; it can write to Downloads,
                                -- and this script (which isn't Mail) moves it on
                                set staging to (POSIX path of (path to downloads folder)) & stamp & "-" & fileName
                                try
                                    save theAttachment in POSIX file staging
                                    do shell script "mv " & quoted form of staging & " " & quoted form of target
                                end try
                            end try
                        end if
                    end repeat
                end repeat
            end perform mail action with messages
        end using terms from
        """
    }

    /// Compiles the script into `folder` (Mail's scripts folder unless testing); returns where.
    /// `name` replaces a script already installed under another name, which a Mail rule runs.
    @discardableResult
    public static func install(inbox: URL, in folder: URL = scriptsFolder, named name: String = scriptName) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        compiler.arguments = ["-o", destination.path]
        let input = Pipe(), errors = Pipe()
        compiler.standardInput = input
        compiler.standardError = errors
        try compiler.run()
        input.fileHandleForWriting.write(Data(source(inbox: inbox).utf8))
        try input.fileHandleForWriting.close()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw Failure(message.isEmpty ? "couldn't compile the Mail script" : message)
        }
        return destination
    }

    public static func isInstalled(in folder: URL = scriptsFolder) -> Bool {
        installedName(in: folder) != nil
    }

    /// The installed script's name, without ".scpt": HomeClerk's, or the one the app installed under
    /// its old name (a Mail rule may run it, and it saves to the same inbox).
    /// Every installed script's file name: HomeClerk's, and the one from before the rename.
    public static func installedFiles(in folder: URL = scriptsFolder) -> [String] {
        [scriptName, Legacy.mailScriptName].filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    public static func installedName(in folder: URL = scriptsFolder) -> String? {
        [scriptName, Legacy.mailScriptName]
            .first { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            .map { $0.replacingOccurrences(of: ".scpt", with: "") }
    }

    /// Backslashes and quotes, escaped for an AppleScript string.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
