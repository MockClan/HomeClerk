import Foundation
import PDFKit

public enum Originals {
    struct CopyRecord: Codable {
        var id: String
        var sha256: String
        var copiedAt: Date
        var proof: Proof?
    }
    struct Proof: Codable {
        struct Output: Codable {
            var documentID: String
            var sha256: String
            var pages: [Int]
        }
        var pageCount: Int
        var outputs: [Output]
    }
    struct Filing: Sendable {
        struct Output: Sendable {
            var entry: DocumentIndex.Entry
            var pages: [Int]
        }
        var sourceSHA256: String
        var pageCount: Int
        var outputs: [Output]
    }

    static func recordURL(for original: URL) -> URL {
        original.deletingLastPathComponent().appendingPathComponent(".\(original.lastPathComponent).original.json")
    }

    /// Preserve the exact bytes with their own identity. A failed record write leaves the PDF
    /// intact, but it can never become a cleanup candidate without its proof.
    static func preserve(_ source: URL, in folder: URL) throws {
        try PrivateFolder.secure(folder)
        let data = try Data(contentsOf: source)
        let destination = FileOrganizer.unique(folder.appendingPathComponent(source.lastPathComponent))
        try FileOrganizer.requireInside(destination, folder)
        try PrivateFile.write(data, to: destination)
        try PrivateFile.writeJSON(CopyRecord(id: UUID().uuidString, sha256: BackfillApplier.sha256(data),
            copiedAt: Date(), proof: nil), to: recordURL(for: destination))
    }

    /// A copy of exactly these bytes is kept in `folder`, with its record, and still matches.
    static func keepsVerifiedCopy(of bytes: Data, in folder: URL) -> Bool {
        let sha = BackfillApplier.sha256(bytes)
        return files(in: folder).contains { original in
            guard let record = PrivateFile.readJSON(CopyRecord.self, from: recordURL(for: original)), record.sha256 == sha,
                  let data = try? Data(contentsOf: original) else { return false }
            return data == bytes
        }
    }

    /// Called only after the PDF/index transaction committed and all finishing steps completed.
    /// An interrupted or failed proof write conservatively keeps the original out of cleanup.
    static func recordFiling(_ filing: Filing, in folder: URL, organized: URL) throws {
        guard !filing.outputs.isEmpty,
              Set(filing.outputs.map { $0.entry.documentID }).count == filing.outputs.count,
              complete(filing.outputs.map(\.pages), pageCount: filing.pageCount) else { return }
        var proof = Proof(pageCount: filing.pageCount, outputs: [])
        for output in filing.outputs {
            let url = URL(fileURLWithPath: output.entry.path)
            try FileOrganizer.requireInside(url, organized)
            guard output.pages.count == 2,
                  PDFDocument(url: url)?.pageCount == output.pages[1] - output.pages[0] + 1 else { return }
            proof.outputs.append(.init(documentID: output.entry.documentID,
                sha256: BackfillApplier.sha256(try Data(contentsOf: url)), pages: output.pages))
        }
        for original in files(in: folder) {
            let recordURL = recordURL(for: original)
            guard FileOrganizer.isInside(recordURL, folder),
                  var record = PrivateFile.readJSON(CopyRecord.self, from: recordURL),
                  record.sha256 == filing.sourceSHA256,
                  BackfillApplier.sha256(try Data(contentsOf: original)) == record.sha256 else { continue }
            record.proof = proof
            try PrivateFile.writeJSON(record, to: recordURL)
        }
    }

    /// Only old, unchanged copies with complete, indexed, unchanged filed outputs qualify.
    /// Files from older versions without provenance records are deliberately retained.
    public static func clearable(in folder: URL, documents: [DocumentIndex.Entry], olderThan days: Int = 90,
                                 now: Date = Date()) -> [ClearableOriginal] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let organized = folder.deletingLastPathComponent().appendingPathComponent("Organized")
        let byID = Dictionary(grouping: documents, by: \.documentID)
        return files(in: folder).compactMap { original in
            guard !Task.isCancelled else { return nil }
            let recordURL = recordURL(for: original)
            guard FileOrganizer.isInside(recordURL, folder),
                  let record = PrivateFile.readJSON(CopyRecord.self, from: recordURL),
                  UUID(uuidString: record.id) != nil, record.copiedAt < cutoff,
                  let proof = record.proof, !proof.outputs.isEmpty,
                  Set(proof.outputs.map(\.documentID)).count == proof.outputs.count,
                  complete(proof.outputs.map(\.pages), pageCount: proof.pageCount),
                  let bytes = try? Data(contentsOf: original), BackfillApplier.sha256(bytes) == record.sha256,
                  PDFDocument(url: original)?.pageCount == proof.pageCount else { return nil }
            for output in proof.outputs {
                guard let matches = byID[output.documentID], matches.count == 1 else { return nil }
                let path = URL(fileURLWithPath: matches[0].path)
                guard FileOrganizer.isInside(path, organized),
                      let data = try? Data(contentsOf: path), BackfillApplier.sha256(data) == output.sha256,
                      PDFDocument(url: path)?.pageCount == output.pages[1] - output.pages[0] + 1 else { return nil }
            }
            return ClearableOriginal(url: original, size: Int64(bytes.count), copied: record.copiedAt)
        }.sorted { $0.copied < $1.copied }
    }

    /// Copies made before HomeClerk kept filing records, so they can never be verified like newer
    /// ones. Listed — for clearing only after you confirm, into the Trash — when they're older than
    /// `days`, no scan by that name is still waiting in `pending` (the Inbox or Review), and there's
    /// evidence they were filed: the duplicate list has their exact bytes filed at a document still
    /// in Organized, or a filed document came from a scan of the same name ("_2" suffix aside).
    /// Copies with no such evidence are kept.
    public static func olderCopies(in folder: URL, documents: [DocumentIndex.Entry], pending: [URL],
                                   fingerprints: DuplicateDetector? = nil, olderThan days: Int = 90,
                                   now: Date = Date()) -> [ClearableOriginal] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let organized = folder.deletingLastPathComponent().appendingPathComponent("Organized")
        let filedScans = Set(documents.filter {
            FileOrganizer.isInside(URL(fileURLWithPath: $0.path), organized) && FileManager.default.fileExists(atPath: $0.path)
        }.map { scanName($0.source) })
        let waiting = Set(pending.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map(scanName)
        })
        return files(in: folder).compactMap { original in
            guard !Task.isCancelled, !FileManager.default.fileExists(atPath: recordURL(for: original).path) else { return nil }
            let name = scanName(original.lastPathComponent)
            guard !waiting.contains(name),
                  let values = try? original.resourceValues(forKeys: [.creationDateKey, .fileSizeKey]),
                  let copied = values.creationDate, copied < cutoff else { return nil }
            func filedByFingerprint() -> Bool {
                guard let fingerprints, let bytes = try? Data(contentsOf: original),
                      let label = fingerprints.exactDuplicate(sha256: BackfillApplier.sha256(bytes)) else { return false }
                let filed = organized.appendingPathComponent(label)
                return FileOrganizer.isInside(filed, organized) && FileManager.default.fileExists(atPath: filed.path)
            }
            guard filedScans.contains(name) || filedByFingerprint() else { return nil }
            return ClearableOriginal(url: original, size: Int64(values.fileSize ?? 0), copied: copied)
        }.sorted { $0.copied < $1.copied }
    }

    /// "scan0042_2.pdf" → "scan0042.pdf", lowercased: the scan's name before the "_2", "_3"…
    /// FileOrganizer.unique adds on a clash. Scanner counters such as "_0001" start with a zero and
    /// are part of the name — stripping them would make every scan from one day look alike.
    static func scanName(_ name: String) -> String {
        let url = URL(fileURLWithPath: name)
        var stem = url.deletingPathExtension().lastPathComponent
        if let range = stem.range(of: #"_[1-9][0-9]?$"#, options: .regularExpression) { stem.removeSubrange(range) }
        return (stem + "." + url.pathExtension).lowercased()
    }

    private static func files(in folder: URL) -> [URL] {
        guard FileOrganizer.isInside(folder, folder) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []).filter {
                $0.pathExtension.lowercased() == "pdf" && FileOrganizer.isInside($0, folder)
            }
    }

    private static func complete(_ ranges: [[Int]], pageCount: Int) -> Bool {
        guard ranges.allSatisfy({ $0.count == 2 }) else { return false }
        let documents = ranges.map { FacetDocument(firstPage: $0[0], lastPage: $0[1], facets: DocumentFacets(), confidence: 1) }
        return FacetDocument.pageCoverageProblem(documents, pageCount: pageCount) == nil
    }
}
