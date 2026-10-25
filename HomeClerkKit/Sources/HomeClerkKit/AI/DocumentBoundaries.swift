import Foundation
import PDFKit

// Finding where each document starts in a pile scanned together. Local readers lose count when one
// request has to name every document's pages, and Apple's small context can't hold a long pile. So
// a pile is read in two steps: first, from a short excerpt of each page, which pages start a new
// document; then each document on its own, with its own page images and full text.

/// A reader that can say, from short excerpts of each page, where new documents start.
public protocol BoundaryFinding: FacetAnalyzer {
    /// The pages (1-based, within the excerpts given) that start a new document; nil when the
    /// reader couldn't answer.
    func documentStarts(excerpts: String, pageCount: Int) async -> [Int]?
}

public enum DocumentBoundaries {
    /// Pages asked about in one request; longer piles are asked about in windows this size.
    static let window = 10

    static let instructions = """
        You sort a pile of scanned household paperwork into its separate documents. You get a short \
        excerpt of each page — its first lines and its last lines — and say which pages begin a new \
        document.

        A new document usually begins with its own letterhead, title, or date, from a different sender \
        or about a different matter. A page does not begin a new document when it continues the one \
        before: the next page of a statement, bill, or letter ("Page 2 of 3"), a form's continuation, \
        an enclosure the letter mentions, or the receipt for paying the invoice on the page before. \
        Page 1 always begins a document. Answer with every page that begins one.
        """

    static func prompt(excerpts: String, pageCount: Int) -> String {
        "This pile has \(pageCount) page\(pageCount == 1 ? "" : "s").\n\n\(excerpts)\n\nWhich pages begin a new document?"
    }

    /// A page's first and last lines: where letterheads, titles, dates, and "Page 2 of 3" are.
    static func excerpt(_ text: String, head: Int = 7, tail: Int = 2) -> String {
        let lines = text.split(separator: "\n").map { String($0.trimmingCharacters(in: .whitespaces).prefix(90)) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "(no text — blank or a picture)" }
        guard lines.count > head + tail else { return lines.joined(separator: "\n") }
        return (lines.prefix(head) + ["…"] + lines.suffix(tail)).joined(separator: "\n")
    }

    static func excerpts(_ pages: [String], numberedFrom first: Int = 1) -> String {
        pages.enumerated().map { "=== Page \($0.offset + first) ===\n\(excerpt($0.element))" }.joined(separator: "\n\n")
    }

    /// "Page 2 of 3" printed on a page: which page of how many, when there is one.
    static func printedPageNumber(_ text: String) -> (page: Int, of: Int)? {
        guard let match = text.firstMatch(of: /(?i)\bpage\s+(\d{1,3})\s*(?:of|\/)\s*(\d{1,3})\b/),
              let page = Int(match.1), let total = Int(match.2), page >= 1, page <= total else { return nil }
        return (page, total)
    }

    /// The reader's starts, corrected by what the pages themselves say: page 1 always starts; a
    /// page printed "Page 2 of 3" (or later) continues the one before; a page printed "Page 1 of 3"
    /// starts one; a page with no text never starts one (it's a blank back or a picture).
    static func corrected(_ starts: [Int], pages: [String]) -> [Int] {
        var result = Set(starts.filter { $0 >= 1 && $0 <= pages.count })
        result.insert(1)
        for (index, text) in pages.enumerated() where index > 0 {
            let number = index + 1
            if let printed = printedPageNumber(text) {
                if printed.page > 1 { result.remove(number) } else if printed.of > 1 { result.insert(number) }
            }
            if text.allSatisfy(\.isWhitespace) { result.remove(number) }
        }
        return result.sorted()
    }

    /// Each document's pages, from the pages that start one.
    static func ranges(starts: [Int], pageCount: Int) -> [ClosedRange<Int>] {
        zip(starts, starts.dropFirst().map { $0 - 1 } + [pageCount]).map { $0...$1 }
    }

    /// Asks `reader` about the pile a window at a time. A window after the first repeats the page
    /// before it, for context, and only its own pages' answers count. Nil when any window fails.
    static func starts(_ pages: [String], reader: any BoundaryFinding) async -> [Int]? {
        var starts: [Int] = [1]
        var first = 1
        while first <= pages.count {
            let context = first == 1 ? 1 : first - 1
            let last = min(context + window - 1, pages.count)
            let slice = Array(pages[(context - 1)..<last])
            guard let found = await reader.documentStarts(excerpts: excerpts(slice), pageCount: slice.count) else { return nil }
            starts += found.map { $0 + context - 1 }.filter { $0 >= first && $0 <= last }
            first = last + 1
        }
        return Array(Set(starts)).sorted()
    }
}

/// Reads a scan of several pages in two steps: where documents start, then each document on its
/// own. A scan of one page is read as is.
public struct BoundaryFindingAnalyzer: FacetAnalyzer {
    public let reader: any BoundaryFinding

    public init(_ reader: any BoundaryFinding) { self.reader = reader }

    public var modelName: String { reader.modelName }
    public var isPaid: Bool { reader.isPaid }

    public func analyze(ocrText: String, pageCount: Int, pdf: URL) async -> FacetAnalysis {
        let pages = TextRecognizer.pages(of: ocrText)
        guard pageCount > 1, pages.count == pageCount,
              let found = await DocumentBoundaries.starts(pages, reader: reader) else {
            return await reader.analyze(ocrText: ocrText, pageCount: pageCount, pdf: pdf)
        }
        let ranges = DocumentBoundaries.ranges(starts: DocumentBoundaries.corrected(found, pages: pages), pageCount: pageCount)
        guard ranges.count > 1 else { return Self.oneDocument(await reader.analyze(ocrText: ocrText, pageCount: pageCount, pdf: pdf),
                                                              pages: 1...pageCount) }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("homeclerk-parts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var combined = FacetAnalysis(), summaries: [String] = []
        combined.model = reader.modelName
        for range in ranges {
            if Task.isCancelled { return .failed("Cancelled") }
            let part: URL
            do { part = try Self.write(pdf, pages: range, in: folder) } catch {
                return await reader.analyze(ocrText: ocrText, pageCount: pageCount, pdf: pdf)
            }
            let text = TextRecognizer.joined(Array(pages[(range.lowerBound - 1)...(range.upperBound - 1)]))
            let analysis = Self.oneDocument(await reader.analyze(ocrText: text, pageCount: range.count, pdf: part), pages: range)
            if let error = analysis.error {
                var failed = FacetAnalysis.failed("Pages \(Self.label(range)): \(error)", transient: analysis.isTransientFailure,
                                                  retryAfterSeconds: analysis.retryAfterSeconds)
                failed.model = reader.modelName
                return failed
            }
            combined.documents += analysis.documents
            summaries.append("Pages \(Self.label(range)): \(analysis.summary)")
        }
        combined.summary = "Found \(ranges.count) documents in this scan.\n" + summaries.joined(separator: "\n")
        return combined
    }

    /// One document covering `pages` of the whole scan: a reader that split a part further is
    /// overruled (the boundary step already decided), keeping its first document's details.
    static func oneDocument(_ analysis: FacetAnalysis, pages: ClosedRange<Int>) -> FacetAnalysis {
        guard analysis.error == nil, let first = analysis.documents.min(by: { $0.firstPage < $1.firstPage }) else { return analysis }
        var result = analysis
        result.documents = [FacetDocument(firstPage: pages.lowerBound, lastPage: pages.upperBound, facets: first.facets,
                                          confidence: analysis.documents.map(\.confidence).min() ?? first.confidence)]
        return result
    }

    static func write(_ pdf: URL, pages: ClosedRange<Int>, in folder: URL) throws -> URL {
        guard let source = PDFDocument(url: pdf) else { throw PDFTools.Failure("The scan couldn't be opened.") }
        let part = PDFDocument()
        for number in pages {
            guard let page = source.page(at: number - 1)?.copy() as? PDFPage else { throw PDFTools.Failure("Page \(number) is missing.") }
            part.insert(page, at: part.pageCount)
        }
        guard let data = part.dataRepresentation() else { throw PDFTools.Failure("A part couldn't be saved.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("pages-\(pages.lowerBound)-\(pages.upperBound).pdf")
        try PrivateFile.write(data, to: url)
        return url
    }

    static func label(_ range: ClosedRange<Int>) -> String {
        range.count == 1 ? "\(range.lowerBound)" : "\(range.lowerBound)–\(range.upperBound)"
    }
}
