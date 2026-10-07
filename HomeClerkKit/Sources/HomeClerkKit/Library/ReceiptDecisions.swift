import Foundation

/// Explicit pair decisions survive path/facet changes. Corrupt history disables matching rather
/// than losing rejections or silently treating the store as empty.
public struct ReceiptDecisions: Sendable {
    public static let fileName = "receipt-matches.json"
    public struct Record: Codable, Equatable, Sendable, Identifiable {
        public var id: String { Self.key(billID, receiptID) }
        public let billID: String
        public let receiptID: String
        public let confirmed: Bool
        public let revision: UUID
        public let at: Date
        public var billName: String? = nil
        public var receiptName: String? = nil
        static func key(_ bill: String, _ receipt: String) -> String {
            Data(bill.utf8).base64EncodedString() + ":" + Data(receipt.utf8).base64EncodedString()
        }
    }
    public struct Snapshot: Equatable, Sendable {
        public let records: [Record]
        public let available: Bool
        public static let empty = Snapshot(records: [], available: true)
        public static let unavailable = Snapshot(records: [], available: false)
        public func decision(billID: String, receiptID: String) -> Bool? {
            records.first { $0.billID == billID && $0.receiptID == receiptID }?.confirmed
        }
    }
    public struct Change: Sendable {
        public let billID: String
        public let receiptID: String
        public let before: Record?
        public let after: Record?
    }
    struct Conflict: Error, LocalizedError {
        var errorDescription: String? { "This bill or receipt is already confirmed with another document. Reset that decision before choosing a different pair." }
    }
    struct Changed: Error, LocalizedError {
        var errorDescription: String? { "This receipt decision changed since the action. Refresh before trying again." }
    }
    public let folder: URL
    private var url: URL { folder.appendingPathComponent(Self.fileName) }
    private static let lock = NSLock()
    public init(folder: URL) { self.folder = folder }
    public func snapshot() throws -> Snapshot { try Self.lock.withLock { Snapshot(records: try read(), available: true) } }

    @discardableResult
    public func set(_ confirmed: Bool?, billID: String, receiptID: String,
                    billName: String? = nil, receiptName: String? = nil) throws -> Change {
        try Self.lock.withLock {
            guard !billID.isEmpty, !receiptID.isEmpty, billID != receiptID else { throw CocoaError(.fileReadCorruptFile) }
            var records = try read()
            let before = records.first { $0.billID == billID && $0.receiptID == receiptID }
            records.removeAll { $0.billID == billID && $0.receiptID == receiptID }
            if confirmed == true, records.contains(where: { $0.confirmed && ($0.billID == billID || $0.receiptID == receiptID) }) { throw Conflict() }
            let after = confirmed.map { Record(billID: billID, receiptID: receiptID, confirmed: $0, revision: UUID(), at: Date(),
                billName: billName ?? before?.billName, receiptName: receiptName ?? before?.receiptName) }
            if let after { records.append(after) }
            try PrivateFile.writeJSON(records, to: url)
            return Change(billID: billID, receiptID: receiptID, before: before, after: after)
        }
    }

    public func undo(_ change: Change) throws {
        try Self.lock.withLock {
            var records = try read()
            let current = records.first { $0.billID == change.billID && $0.receiptID == change.receiptID }
            guard current?.revision == change.after?.revision else { throw Changed() }
            records.removeAll { $0.billID == change.billID && $0.receiptID == change.receiptID }
            if let before = change.before {
                if before.confirmed, records.contains(where: { $0.confirmed && ($0.billID == before.billID || $0.receiptID == before.receiptID) }) { throw Conflict() }
                records.append(before)
            }
            try PrivateFile.writeJSON(records, to: url)
        }
    }

    private func read() throws -> [Record] {
        try FileOrganizer.requireInside(url, folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([Record].self, from: Data(contentsOf: url))
        let confirmed = records.filter(\.confirmed)
        guard Set(records.map(\.id)).count == records.count,
              records.allSatisfy({ !$0.billID.isEmpty && !$0.receiptID.isEmpty && $0.billID != $0.receiptID }),
              Set(confirmed.map(\.billID)).count == confirmed.count,
              Set(confirmed.map(\.receiptID)).count == confirmed.count else { throw CocoaError(.fileReadCorruptFile) }
        return records
    }
}

public struct ReceiptMatchProposal: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable { case suggested = "Needs Review", automatic = "Automatic", confirmed = "Confirmed", rejected = "Rejected" }
    public var id: String { ReceiptDecisions.Record.key(bill.documentID, receipt.documentID) }
    public let bill: DocumentIndex.Entry
    public let receipt: DocumentIndex.Entry
    public let status: Status
    public let reasons: [String]
    public let canConfirm: Bool
    public let active: Bool
}
