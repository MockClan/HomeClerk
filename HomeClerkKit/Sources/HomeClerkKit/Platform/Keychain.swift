import Foundation

/// The Anthropic API key in the macOS Keychain (service "HomeClerk", account "AnthropicApiKey").
/// Read with /usr/bin/security: the entry is created by that tool, so reading it the same way
/// doesn't trigger a Keychain access prompt.
public enum Keychain {
    public static let service = "HomeClerk"
    public static let account = "AnthropicApiKey"

    /// The stored key, or nil when there isn't one.
    public static func readAPIKey(service: String = service) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}

extension Keychain {
    /// Anthropic keys are "sk-ant-" plus letters, digits, '-' and '_'. Anything else is rejected,
    /// which also keeps the value safe to pass to `security -i`'s command parser.
    public static func isValidKey(_ key: String) -> Bool {
        key.hasPrefix("sk-ant-") && key.count > 20
            && key.unicodeScalars.allSatisfy { ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) || $0 == "-" || $0 == "_" }
    }

    /// Stores (or replaces) the key, writing it through `security -i` on standard input so it never
    /// appears in the process list.
    public static func storeAPIKey(_ key: String) -> Bool {
        guard isValidKey(key) else { return false }
        return run(["-i"], input: "add-generic-password -U -s \(service) -a \(account) -w \(key)\n")
    }

    /// Removes the stored key; false when there wasn't one.
    @discardableResult
    public static func deleteAPIKey() -> Bool {
        run(["delete-generic-password", "-s", service, "-a", account])
    }

    private static func run(_ arguments: [String], input: String? = nil) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        process.standardInput = stdin
        do { try process.run() } catch { return false }
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
