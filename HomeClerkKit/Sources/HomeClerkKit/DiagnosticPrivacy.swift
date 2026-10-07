import Foundation

/// Diagnostic exports use allowlisted summaries, rather than trying to recognize every secret
/// that could occur in a path, URL, server response, or localized error message.
public enum DiagnosticPrivacy {
    public static let omittedError = "Error details omitted for privacy; inspect Activity locally."

    /// Export endpoint topology, withholding hostname, user info, path, query, and fragment.
    public static func endpoint(_ url: URL) -> String {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else {
            return "custom endpoint (URL omitted)"
        }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        let port = url.port.map { ", port \($0)" } ?? ""
        return "\(scheme), \(local ? "loopback" : "remote host")\(port) (URL omitted)"
    }

    public static func logCategory(_ category: String) -> String {
        ["finishing", "folders", "duplicates", "facets", "ollama", "apple", "processor", "claude", "inbox"]
            .contains(category) ? category : "other"
    }
}
