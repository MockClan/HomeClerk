import Foundation

public enum FinishingStep: String, Codable, CaseIterable, Sendable {
    case searchable, tags, reminders
    public var title: String {
        switch self {
        case .searchable: "Searchable text"
        case .tags: "Finder tags"
        case .reminders: "Reminders"
        }
    }
}

public struct FinishingFailure: Codable, Equatable, Sendable {
    public let step: FinishingStep
    public let detail: String
}

public struct FinishingOutcome: Sendable {
    public var reminders: [String] = []
    public var failures: [FinishingFailure] = []
    public var warnings: [String] = []
}

/// Private repair records keyed by index identity. Unreadable records must never be overwritten
/// with an empty history. The shared lock serializes all instances within the app process.
public struct FinishingIssues: Sendable {
    public static let fileName = "finishing-issues.json"
    public struct Record: Codable, Sendable, Identifiable {
        public var id: String { documentID }
        public let documentID: String
        public var path: String
        public var failures: [FinishingFailure]
        public var updatedAt: Date
        public var reminderPrevious: [ReminderItem]? = nil
    }
    public let folder: URL
    private static let lock = NSLock()
    private var url: URL { folder.appendingPathComponent(Self.fileName) }
    public init(folder: URL) { self.folder = folder }
    public func load() throws -> [Record] { try Self.lock.withLock { try read() } }

    /// Resolve identity from the current index; never use a repair log's stale or edited path.
    public func retry(documentID: String, settings: HomeClerkSettings, index: DocumentIndex,
                      finisher: Finisher? = nil, duplicates: DuplicateDetector? = nil) async throws -> FinishingOutcome {
        guard let repair = try load().first(where: { $0.documentID == documentID }) else { return FinishingOutcome() }
        let matches = DocumentLibrary.load(index).documents.filter { $0.documentID == documentID }
        guard matches.count == 1, let entry = matches.first else { throw CocoaError(.fileReadNoSuchFile) }
        let file = URL(fileURLWithPath: entry.path)
        let operation = try DocumentOperations.acquire([file])
        defer { operation.release() }
        try FileOrganizer.requireInside(settings.outboxFolder, settings.basePath)
        try FileOrganizer.requireInside(file, settings.outboxFolder)
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let worker = finisher ?? Finisher(settings)
        var outcome = await worker.finish(file, facets: entry.facets, today: DocumentProcessor.localToday(),
            documentID: documentID, steps: Set(repair.failures.map(\.step)), synchronizeReminders: true)
        // Preserve existing original-scan fingerprints; add the repaired PDF as another exact match.
        // A concurrent edit/rename must not be registered under the older metadata.
        if let duplicates, DocumentLibrary.load(index).documents.contains(entry) {
            do {
                try FileOrganizer.requireInside(file, settings.outboxFolder)
                let hash = BackfillApplier.sha256(try Data(contentsOf: file))
                let label = FileOrganizer.relativePath(file, in: settings.outboxFolder) ?? file.lastPathComponent
                duplicates.register(ocrText: Finisher.text(of: file), sha256: hash, facets: entry.facets, label: label)
            } catch { outcome.warnings.append("Finishing retry completed, but duplicate recognition needs attention: \(error)") }
        }
        return outcome
    }

    public func update(documentID: String, path: String, attempted: Set<FinishingStep>, failures: [FinishingFailure],
                       reminderPrevious: [ReminderItem] = []) throws {
        try Self.lock.withLock {
            var records = try read()
            guard records.contains(where: { $0.documentID == documentID }) || !failures.isEmpty else { return }
            let prior = records.first { $0.documentID == documentID }
            let old = prior?.failures ?? []
            let remaining = old.filter { !attempted.contains($0.step) } + failures
            records.removeAll { $0.documentID == documentID }
            if !remaining.isEmpty {
                let context = attempted.contains(.reminders)
                    ? (failures.contains(where: { $0.step == .reminders }) ? reminderPrevious : nil)
                    : prior?.reminderPrevious
                records.append(Record(documentID: documentID, path: path, failures: remaining, updatedAt: Date(), reminderPrevious: context))
            }
            try PrivateFile.writeJSON(records, to: url)
        }
    }

    private func read() throws -> [Record] {
        try FileOrganizer.requireInside(url, folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([Record].self, from: Data(contentsOf: url))
        guard Set(records.map(\.documentID)).count == records.count,
              records.allSatisfy({ !$0.documentID.isEmpty && Set($0.failures.map(\.step)).count == $0.failures.count }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return records
    }
}
