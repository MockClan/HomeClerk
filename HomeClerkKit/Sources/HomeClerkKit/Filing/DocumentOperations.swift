import Foundation

/// In-process per-path exclusion. Batch acquisition is atomic; unrelated documents may proceed.
public enum DocumentOperations {
    public struct Busy: Error, LocalizedError {
        public var errorDescription: String? { "This document is already being changed. Wait for that operation to finish." }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var owners: [String: UUID] = [:]
    public static func acquire(_ urls: [URL]) throws -> Lease {
        let paths = Set(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }), owner = UUID()
        return try lock.withLock {
            guard paths.allSatisfy({ owners[$0] == nil }) else { throw Busy() }
            for path in paths { owners[path] = owner }
            return Lease(paths: paths, owner: owner)
        }
    }
    public final class Lease: Sendable {
        private let paths: Set<String>
        private let owner: UUID
        fileprivate init(paths: Set<String>, owner: UUID) { self.paths = paths; self.owner = owner }
        public func release() {
            DocumentOperations.lock.withLock {
                for path in paths where DocumentOperations.owners[path] == owner { DocumentOperations.owners[path] = nil }
            }
        }
        deinit { release() }
    }
}
