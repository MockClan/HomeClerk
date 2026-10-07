import CryptoKit
import Foundation
import PDFKit

/// Copies and indexes a filing before retiring its source. Pending journals are reconciled
/// before the inbox watcher starts, so a crash cannot strand an unindexed PDF or lose a scan.
struct FilingTransaction: Sendable {
    struct Output: Sendable {
        var destination: URL
        var entry: DocumentIndex.Entry
        var pages: ClosedRange<Int>? = nil
    }

    struct Result: Sendable {
        var entries: [DocumentIndex.Entry]
        var warnings: [String]
        var originalFiling: Originals.Filing?

        func recordOriginalFiling(settings: HomeClerkSettings) -> [String] {
            guard let originalFiling else { return [] }
            do {
                try Originals.recordFiling(originalFiling, in: settings.originalsFolder, organized: settings.outboxFolder)
                return []
            } catch { return ["Filing saved; original cleanup proof could not be recorded: \(error.localizedDescription)"] }
        }
    }

    struct Journal: Codable {
        struct Part: Codable {
            var destination: String
            var entry: DocumentIndex.Entry
            var hash: String?
            var replacesSource: Bool
        }
        var id: String
        var source: String
        var sourceHash: String
        var deleteSidecars: Bool
        var parts: [Part]
    }

    enum Checkpoint: Sendable { case prepared, placed(Int), indexed }
    /// Test-only interruption: leaves the same durable state as a process exiting at a checkpoint.
    struct Interrupted: Error {}
    struct Failure: LocalizedError {
        var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    let settings: HomeClerkSettings
    let index: DocumentIndex
    var checkpoint: @Sendable (Checkpoint) throws -> Void = { _ in }
    private static let lock = NSLock()
    var root: URL { settings.basePath.appendingPathComponent(".homeclerk-operations") }

    func execute(source: URL, outputs: [Output], deleteSidecars: Bool = false, operationID: String = UUID().uuidString) throws -> Result {
        try Self.lock.withLock {
            guard UUID(uuidString: operationID) != nil, !outputs.isEmpty, safeSource(source), safe(root, inside: settings.basePath),
                  outputs.allSatisfy({ safe($0.destination, inside: settings.outboxFolder) }),
                  Set(outputs.map { $0.destination.standardizedFileURL.path }).count == outputs.count else {
                throw Failure("Invalid filing operation; the source was preserved")
            }
            try PrivateFolder.secure(root)
            let id = operationID
            let folder = root.appendingPathComponent(id)
            try PrivateFolder.secure(folder)
            var journal = Journal(id: id, source: source.path, sourceHash: try hash(source), deleteSidecars: deleteSidecars,
                parts: outputs.map { output in
                    var entry = output.entry
                    entry.path = output.destination.path
                    entry.operationID = id
                    return Journal.Part(destination: output.destination.path, entry: entry, hash: nil,
                        replacesSource: output.destination.standardizedFileURL == source.standardizedFileURL)
                })
            let originalFiling: Originals.Filing?
            if [settings.inboxFolder, settings.reviewFolder].contains(where: { safe(source, inside: $0) }),
               let count = PDFDocument(url: source)?.pageCount, count > 0 {
                originalFiling = Originals.Filing(sourceSHA256: journal.sourceHash, pageCount: count,
                    outputs: zip(outputs, journal.parts).map { output, part in
                        .init(entry: part.entry, pages: output.pages.map { [$0.lowerBound, $0.upperBound] } ?? [1, count])
                    })
            } else { originalFiling = nil }
            let journalURL = folder.appendingPathComponent("journal.json")
            try PrivateFile.writeJSON(journal, to: journalURL)
            var committed = false
            do {
                for (i, output) in outputs.enumerated() where !journal.parts[i].replacesSource {
                    let stage = staged(i, in: folder)
                    if let pages = output.pages { try PDFTools.split(source, pages: pages, to: stage) }
                    else { try FileManager.default.copyItem(at: source, to: stage) }
                    journal.parts[i].hash = try hash(stage)
                }
                try PrivateFile.writeJSON(journal, to: journalURL)
                try checkpoint(.prepared)
                for (i, part) in journal.parts.enumerated() where !part.replacesSource {
                    try FileManager.default.moveItem(at: staged(i, in: folder), to: URL(fileURLWithPath: part.destination))
                    try checkpoint(.placed(i))
                }
                guard try hash(source) == journal.sourceHash else {
                    throw Failure("The scan changed while filing; its source was preserved")
                }
                try index.append(journal.parts.map(\.entry))
                committed = true
                try checkpoint(.indexed)
                let warnings = cleanupCommitted(journal, folder: folder)
                return Result(entries: journal.parts.map(\.entry), warnings: warnings, originalFiling: originalFiling)
            } catch is Interrupted {
                throw Interrupted()
            } catch {
                if committed {
                    return Result(entries: journal.parts.map(\.entry), warnings: ["Filing was saved, but cleanup needs recovery: \(error.localizedDescription)"], originalFiling: originalFiling)
                }
                do { try rollback(journal, folder: folder) }
                catch { throw Failure("Filing failed. The source and recovery journal were preserved: \(error.localizedDescription)") }
                throw error
            }
        }
    }

    /// Uncommitted copies are removed; committed copies retire the unchanged source. Unknown or
    /// changed files are preserved and reported, never silently overwritten or deleted. Throws at
    /// the first operation that can't be finished safely — for Library Health's repair button.
    func recover(only operationID: String? = nil) throws -> Int {
        try Self.lock.withLock {
            if let operationID, UUID(uuidString: operationID) == nil { throw Failure("Invalid recovery selection") }
            var recovered = 0
            for folder in try operationFolders() {
                if let operationID, folder.lastPathComponent != operationID { continue }
                try recoverFolder(folder)
                recovered += 1
            }
            return recovered
        }
    }

    /// What startup recovery did: operations finished, and ones left untouched for Library Health.
    struct Report: Sendable {
        var recovered = 0
        var preserved: [String] = []
    }

    /// Startup: finishes every interrupted operation it safely can and leaves the rest exactly as
    /// they are, reported rather than thrown — one stuck operation mustn't stop HomeClerk watching.
    func recoverWhatIsSafe() -> Report {
        Self.lock.withLock {
            var report = Report()
            let folders: [URL]
            do { folders = try operationFolders() } catch {
                report.preserved.append(error.localizedDescription)
                return report
            }
            for folder in folders {
                do {
                    try recoverFolder(folder)
                    report.recovered += 1
                } catch {
                    report.preserved.append(error.localizedDescription)
                }
            }
            return report
        }
    }

    /// A filing of `source` was interrupted and waits for recovery, so the scan must stay where its
    /// journal expects it rather than going to Review.
    func isPending(source: URL) -> Bool {
        let path = source.standardizedFileURL.path
        return ((try? operationFolders()) ?? []).contains { folder in
            PrivateFile.readJSON(Journal.self, from: folder.appendingPathComponent("journal.json"))
                .map { URL(fileURLWithPath: $0.source).standardizedFileURL.path == path } ?? false
        }
    }

    /// Operation folders in the recovery folder, skipping hidden files Finder or iCloud put there
    /// (.DS_Store, .icloud placeholders).
    private func operationFolders() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard safe(root, inside: settings.basePath) else { throw Failure("The recovery folder is outside HomeClerk") }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func recoverFolder(_ folder: URL) throws {
        guard UUID(uuidString: folder.lastPathComponent) != nil, safe(folder, inside: root) else {
            throw Failure("Unrecognized item in the recovery folder (\(folder.lastPathComponent)); it was preserved")
        }
        let journalURL = folder.appendingPathComponent("journal.json")
        guard let journal = PrivateFile.readJSON(Journal.self, from: journalURL) else {
            let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
            if contents.isEmpty {
                try FileManager.default.removeItem(at: folder)
                return
            }
            throw Failure("An unreadable filing journal was preserved at \(folder.path)")
        }
        guard journal.id == folder.lastPathComponent, safeSource(URL(fileURLWithPath: journal.source)),
              !journal.parts.isEmpty,
              journal.parts.allSatisfy({ safe(URL(fileURLWithPath: $0.destination), inside: settings.outboxFolder)
                  && $0.entry.path == $0.destination && $0.entry.operationID == journal.id
                  && $0.replacesSource == (URL(fileURLWithPath: $0.destination).standardizedFileURL == URL(fileURLWithPath: journal.source).standardizedFileURL) }) else {
            throw Failure("Unsafe filing journal; all files were preserved")
        }
        // An unreadable index is not evidence that the filing never committed.
        if FileManager.default.fileExists(atPath: index.url.path) { _ = try Data(contentsOf: index.url) }
        let entries = index.load()
        let saved = journal.parts.filter { part in entries.contains { $0.operationID == journal.id && $0.path == part.destination } }.count
        if saved == journal.parts.count {
            let warnings = cleanupCommitted(journal, folder: folder)
            guard warnings.isEmpty else { throw Failure(warnings.joined(separator: "\n")) }
        } else if saved == 0 {
            try rollback(journal, folder: folder)
        } else {
            throw Failure("Only part of a filing is indexed; all documents were preserved for recovery")
        }
    }

    private func rollback(_ journal: Journal, folder: URL) throws {
        let source = URL(fileURLWithPath: journal.source)
        guard FileManager.default.fileExists(atPath: source.path), try hash(source) == journal.sourceHash else {
            throw Failure("The source is missing or changed; output copies were preserved")
        }
        for (i, part) in journal.parts.enumerated() where !part.replacesSource {
            let destination = URL(fileURLWithPath: part.destination)
            // A stage still present means the move did not occur: do not touch a conflicting file.
            if FileManager.default.fileExists(atPath: staged(i, in: folder).path) { continue }
            if FileManager.default.fileExists(atPath: destination.path) {
                guard let expected = part.hash, try hash(destination) == expected else {
                    throw Failure("An output changed; it and the source were preserved")
                }
                try FileManager.default.removeItem(at: destination)
            }
        }
        try FileManager.default.removeItem(at: folder)
    }

    private func cleanupCommitted(_ journal: Journal, folder: URL) -> [String] {
        do {
            // Verify every output still exists before retiring the source or its review notes.
            guard journal.parts.allSatisfy({ FileManager.default.fileExists(atPath: $0.destination) }) else {
                throw Failure("A committed output is missing; the source and journal were preserved")
            }
            let source = URL(fileURLWithPath: journal.source)
            if !journal.parts.contains(where: \.replacesSource), FileManager.default.fileExists(atPath: source.path) {
                guard try hash(source) == journal.sourceHash else {
                    throw Failure("The source changed after filing; it and the journal were preserved")
                }
                try FileManager.default.removeItem(at: source)
            }
            if journal.deleteSidecars {
                for sidecar in [ReviewProposal.reasonURL(for: source), ReviewProposal.proposalURL(for: source)]
                where FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
            }
            try FileManager.default.removeItem(at: folder)
            return []
        } catch { return [error.localizedDescription] }
    }

    private func staged(_ i: Int, in folder: URL) -> URL { folder.appendingPathComponent("part-\(i).pdf") }
    private func safeSource(_ url: URL) -> Bool {
        [settings.inboxFolder, settings.reviewFolder, settings.outboxFolder].contains { safe(url, inside: $0) }
    }
    private func safe(_ url: URL, inside folder: URL) -> Bool {
        FileOrganizer.isInside(url, folder)
    }
    private func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}
