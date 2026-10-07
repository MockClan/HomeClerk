import Foundation
import PDFKit

/// A byte-for-byte recovery copy for every PDF rewrite, independent of scanner-original cleanup.
/// These copies stay beside the document in a hidden folder and are never automatically deleted.
public enum PDFTransformation {
    public static func originalsFolder(for pdf: URL) -> URL {
        pdf.deletingLastPathComponent().appendingPathComponent(".homeclerk-pdf-originals", isDirectory: true)
    }

    static func readOriginal(_ pdf: URL) throws -> Data {
        try FileOrganizer.requireInside(pdf, pdf.deletingLastPathComponent())
        guard try pdf.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw PDFTools.Failure("The PDF must be an ordinary file.")
        }
        return try Data(contentsOf: pdf)
    }

    struct Record: Codable {
        var sourceName: String
        var operation: String
        var sha256: String
        var savedAt: Date
    }

    /// PDFKit and page redrawing cannot promise preservation of interactive forms or signatures.
    /// Refuse those rewrites rather than silently flattening a form or invalidating a signature.
    static func requireNoForms(_ source: CGPDFDocument, document: PDFDocument? = nil) throws {
        var form: CGPDFDictionaryRef?
        let hasForm = source.catalog.map { CGPDFDictionaryGetDictionary($0, "AcroForm", &form) } ?? false
        let hasWidget = document.map { pdf in
            (0..<pdf.pageCount).contains { index in
                pdf.page(at: index)?.annotations.contains { $0.type == "Widget" } ?? false
            }
        } ?? false
        guard !hasForm && !hasWidget else {
            throw PDFTools.Failure("This PDF contains interactive forms or signature fields. HomeClerk leaves it unchanged to protect them. Use a separate copy in a PDF editor if you need to transform it.")
        }
    }

    /// The caller validates its staged PDF before publishing it. A backup failure, changed source,
    /// unsafe path, or cancellation must leave the original document in place. With
    /// `alreadyKeptIn` (the _originals folder), no second backup is saved when a verified copy of
    /// these exact bytes is already kept there — as it is for a scan that was just filed.
    static func replace(_ pdf: URL, with staged: URL, original: Data, operation: String, alreadyKeptIn originals: URL? = nil) throws {
        try Task.checkCancellation()
        let parent = pdf.deletingLastPathComponent()
        try FileOrganizer.requireInside(pdf, parent)
        try FileOrganizer.requireInside(staged, parent)
        guard try Data(contentsOf: pdf) == original else {
            throw PDFTools.Failure("The PDF changed during \(operation). It was left unchanged; try again.")
        }
        if let originals, Originals.keepsVerifiedCopy(of: original, in: originals) {
            try Task.checkCancellation()
            guard try Data(contentsOf: pdf) == original else {
                throw PDFTools.Failure("The PDF changed during \(operation). It was left unchanged; try again.")
            }
            _ = try FileManager.default.replaceItemAt(pdf, withItemAt: staged, options: .usingNewMetadataOnly)
            return
        }
        let folder = originalsFolder(for: pdf)
        try FileOrganizer.requireInside(folder, parent)
        try PrivateFolder.secure(folder)
        let sha = BackfillApplier.sha256(original)
        let copy = folder.appendingPathComponent("\(sha).pdf")
        let record = folder.appendingPathComponent("\(sha).json")
        try FileOrganizer.requireInside(copy, parent)
        try FileOrganizer.requireInside(record, parent)
        if FileManager.default.fileExists(atPath: copy.path) {
            guard try Data(contentsOf: copy) == original else {
                throw PDFTools.Failure("The saved PDF original has changed. The document was left unchanged.")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
        } else {
            try PrivateFile.write(original, to: copy)
        }
        guard try Data(contentsOf: copy) == original else {
            throw PDFTools.Failure("Couldn't verify the saved PDF original. The document was left unchanged.")
        }
        try PrivateFile.writeJSON(Record(sourceName: pdf.lastPathComponent, operation: operation,
            sha256: sha, savedAt: Date()), to: record)
        try Task.checkCancellation()
        guard try Data(contentsOf: pdf) == original else {
            throw PDFTools.Failure("The PDF changed during \(operation). It was left unchanged; try again.")
        }
        // Keep the private staged permissions, especially when decrypting a broadly readable input.
        _ = try FileManager.default.replaceItemAt(pdf, withItemAt: staged, options: .usingNewMetadataOnly)
    }
}
