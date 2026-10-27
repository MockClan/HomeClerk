import Foundation
import PDFKit

/// Filed documents that look like pieces of one — the first pages filed from one pile and the
/// rest from another, say.
public struct JoinSuggestion: Equatable, Sendable, Identifiable {
    /// By document, so a rename doesn't forget that you kept them separate.
    public var id: String { pieces.map(\.documentID).sorted().joined(separator: "\n") }
    /// In page order.
    public var pieces: [DocumentIndex.Entry]
    /// The page count printed on them ("Page 3 of 4" → 4).
    public var pageCount: Int
}

public enum Joining {
    /// The printed page number on each page of `url` ("Page 3 of 4" → 3 of 4), nil where there's none.
    static func printedPages(_ url: URL) -> [(page: Int, of: Int)?] {
        guard let pdf = PDFDocument(url: url) else { return [] }
        return (0..<pdf.pageCount).map { index in
            let text = pdf.page(at: index)?.string ?? ""
            return text.matches(of: /(?i)page\s*(\d{1,2})\s*(?:of|\/)\s*(\d{1,2})/).lazy.compactMap { match in
                guard let page = Int(match.1), let total = Int(match.2), page >= 1, page <= total else { return nil }
                return (page, total)
            }.first
        }
    }

    /// Pairs of documents about the same person and of the same kind and date (or from the same
    /// sender, one of them undated), whose printed page numbers fit together in turn into every page
    /// of one document ("Page 1 of 4", "Page 2 of 4" and "Page 3 of 4", "Page 4 of 4"). Pairs you
    /// chose to keep separate (by `id`) aren't suggested again.
    public static func suggestions(_ documents: [DocumentIndex.Entry], keepingSeparate: Set<String> = []) -> [JoinSuggestion] {
        func related(_ a: DocumentIndex.Entry, _ b: DocumentIndex.Entry) -> Bool {
            let x = a.facets, y = b.facets
            return TextRules.key(x.person) == TextRules.key(y.person) && x.area == y.area && x.documentType == y.documentType
                && (x.documentDate == y.documentDate && !x.documentDate.isEmpty
                    || TextRules.key(x.vendor) == TextRules.key(y.vendor) && !x.vendor.isEmpty
                        && (x.documentDate.isEmpty || y.documentDate.isEmpty))
        }
        var printed: [String: [Int: Int]] = [:]
        // Each document's numbered pages, by the page count printed with them (read only when needed)
        func numbered(_ entry: DocumentIndex.Entry) -> [Int: Int] {
            if let known = printed[entry.path] { return known }
            var pages: [Int: Int] = [:]
            for found in printedPages(URL(fileURLWithPath: entry.path)).compactMap({ $0 }) { pages[found.page] = found.of }
            printed[entry.path] = pages
            return pages
        }
        var found: [JoinSuggestion] = []
        for (i, a) in documents.enumerated() {
            if Task.isCancelled { return [] }
            for b in documents[(i + 1)...] where related(a, b) {
                let x = numbered(a), y = numbered(b)
                // Each must hold some of the numbered pages: a whole document isn't a piece
                guard !x.isEmpty, !y.isEmpty, let total = x.values.first, total > 1, (Array(x.values) + Array(y.values)).allSatisfy({ $0 == total }),
                      Set(x.keys).union(y.keys) == Set(1...total) else { continue }
                // One piece's pages all come before the other's (1–2 and 3–4), so joining them in turn keeps page order
                let (front, back) = x.keys.min()! < y.keys.min()! ? (x, y) : (y, x)
                guard front.keys.max()! < back.keys.min()! else { continue }
                let suggestion = JoinSuggestion(pieces: front == x ? [a, b] : [b, a], pageCount: total)
                if !keepingSeparate.contains(suggestion.id) { found.append(suggestion) }
            }
        }
        return found
    }

    /// `pieces` in the order to join them: by their printed page numbers when they all have some,
    /// otherwise by date, as listed.
    public static func ordered(_ pieces: [DocumentIndex.Entry]) -> [DocumentIndex.Entry] {
        let first = pieces.map { entry in printedPages(URL(fileURLWithPath: entry.path)).compactMap { $0?.page }.min() }
        if first.allSatisfy({ $0 != nil }) {
            return zip(pieces, first).sorted { $0.1! < $1.1! }.map(\.0)
        }
        return pieces.enumerated().sorted { a, b in
            let (x, y) = (a.element.facets.documentDate, b.element.facets.documentDate)
            return x == y || x.isEmpty || y.isEmpty ? a.offset < b.offset : x < y
        }.map(\.element)
    }
}

extension ReviewActions {
    public struct Joined: Sendable {
        /// The first piece, which now holds every page; its name, folder, details, and tags are kept.
        public var document: DocumentIndex.Entry
        var original: Data
        /// The other pieces, in the Trash.
        var trashed: [TrashedFile]
    }

    /// Joins filed documents into the first of them, their pages in the order given. The others go
    /// to the Trash; undo puts everything back. All or nothing: if a step fails, what was done is undone.
    public func join(_ pieces: [DocumentIndex.Entry]) throws -> Joined {
        guard pieces.count > 1 else { throw LibraryActionError("Choose at least two documents to combine.") }
        let urls = pieces.map { URL(fileURLWithPath: $0.path) }
        guard Set(urls.map(\.path)).count == urls.count else { throw LibraryActionError("A document was chosen twice.") }
        let operation = try DocumentOperations.acquire(urls)
        defer { operation.release() }
        for url in urls { try requireManaged(url, in: settings.outboxFolder) }
        try requireCurrent(pieces)
        let first = urls[0], original = try Data(contentsOf: first)
        let joined = PDFDocument()
        for url in urls {
            guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else {
                throw LibraryActionError("\(url.lastPathComponent) couldn't be read, so nothing was combined.")
            }
            for index in 0..<pdf.pageCount {
                guard let page = pdf.page(at: index)?.copy() as? PDFPage else {
                    throw LibraryActionError("A page of \(url.lastPathComponent) couldn't be copied, so nothing was combined.")
                }
                joined.insert(page, at: joined.pageCount)
            }
        }
        guard let data = joined.dataRepresentation() else { throw LibraryActionError("The combined document couldn't be saved.") }
        var trashed: [TrashedFile] = []
        do {
            for (url, entry) in zip(urls, pieces).dropFirst() { trashed.append(try moveToTrash(url, facets: entry.facets)) }
            try replaceContents(of: first, with: data)
        } catch {
            for piece in trashed.reversed() { try? FileManager.default.moveItem(at: piece.inTrash, to: piece.original) }
            throw error
        }
        for piece in trashed { forgetFiled(piece.original) }
        rememberFingerprint(first, facets: pieces[0].facets)
        return Joined(document: pieces[0], original: original, trashed: trashed)
    }

    /// Puts the pieces back as they were before they were combined.
    public func undo(_ joined: Joined) throws {
        let first = URL(fileURLWithPath: joined.document.path)
        try requireManaged(first, in: settings.outboxFolder)
        // Nothing is changed unless every piece can go back where it was
        if let taken = joined.trashed.first(where: { FileManager.default.fileExists(atPath: $0.original.path) }) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: taken.original.path])
        }
        for piece in joined.trashed { try restore(piece) }
        let operation = try DocumentOperations.acquire([first])
        defer { operation.release() }
        try replaceContents(of: first, with: joined.original)
        rememberFingerprint(first, facets: joined.document.facets)
    }
}
