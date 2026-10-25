import Foundation
import PDFKit
import Testing
@testable import HomeClerkKit

/// A reader for the boundary step: answers from a script, and reads a part by naming it after its
/// first line (or splits it, when asked to misbehave).
final class ScriptedBoundaryReader: BoundaryFinding, @unchecked Sendable {
    let answers: ([String]) -> [Int]?
    let splitsParts: Bool
    var asked: [Int] = []          // page counts of the excerpts asked about
    var read: [Int] = []           // page counts of the scans read

    init(splitsParts: Bool = false, answers: @escaping ([String]) -> [Int]?) {
        self.answers = answers
        self.splitsParts = splitsParts
    }

    var modelName: String { "Scripted" }
    var isPaid: Bool { false }

    func documentStarts(excerpts: String, pageCount: Int) async -> [Int]? {
        asked.append(pageCount)
        let firstLines = excerpts.components(separatedBy: "=== Page ").dropFirst()
            .map { $0.split(separator: "\n").dropFirst().first.map(String.init) ?? "" }
        return answers(firstLines)
    }

    func analyze(ocrText: String, pageCount: Int, pdf: URL) async -> FacetAnalysis {
        read.append(pageCount)
        let vendor = TextRecognizer.pages(of: ocrText).first?.split(separator: "\n").first.map(String.init) ?? ""
        let facets = DocumentFacets(documentType: "Bill", area: "Utilities", vendor: vendor)
        if splitsParts, pageCount > 1 {
            return FacetAnalysis(documents: [FacetDocument(firstPage: 1, lastPage: 1, facets: facets, confidence: 0.9),
                                             FacetDocument(firstPage: 2, lastPage: pageCount, facets: facets, confidence: 0.8)])
        }
        return FacetAnalysis(documents: [FacetDocument(firstPage: 1, lastPage: pageCount, facets: facets, confidence: 0.9)],
                             summary: "One \(vendor) document")
    }
}

@Suite struct DocumentBoundaryTests {
    let temp = TempFolder()

    @Test func printedPageNumbersAndBlankPagesCorrectTheReader() {
        let pages = ["ACME POWER\nStatement\nPage 1 of 2", "Usage details\nPage 2 of 2", "", "CORNER HARDWARE\nReceipt",
                     "NORTHWIND\nInvoice\nPage 1 of 3"]
        // The reader wrongly starts a document at the statement's second page and at the blank page,
        // and misses page 1 and the three-page invoice. ("Page 1 of 1" alone doesn't start one: a
        // receipt printed that way can belong with the invoice before it.)
        #expect(DocumentBoundaries.corrected([2, 3, 4], pages: pages) == [1, 4, 5])
        #expect(DocumentBoundaries.printedPageNumber("Account summary — page 3 of 4") ?? (0, 0) == (3, 4))
        #expect(DocumentBoundaries.printedPageNumber("Page 5 of 2") == nil)
        #expect(DocumentBoundaries.ranges(starts: [1, 4, 5], pageCount: 6) == [1...3, 4...4, 5...6])
    }

    @Test func longPilesAreAskedAboutInWindows() async throws {
        // 23 pages; a document starts every 3rd page (1, 4, 7, …, 22)
        let pages = (1...23).map { "Page text \($0)" }
        let reader = ScriptedBoundaryReader { lines in
            // Each window's excerpt lists its pages; answer with the positions of "real" starts
            lines.enumerated().compactMap { index, line in
                Int(line.split(separator: " ").last ?? "").flatMap { ($0 - 1) % 3 == 0 ? index + 1 : nil }
            }
        }
        let starts = try #require(await DocumentBoundaries.starts(pages, reader: reader))
        #expect(starts == Array(stride(from: 1, through: 23, by: 3)))
        #expect(reader.asked == [10, 10, 5])   // pages 1–10, 10–19 (10 again for context), 19–23
    }

    func scan(_ pages: [String]) throws -> URL {
        let url = temp.url.appendingPathComponent("pile.pdf")
        try TestPDF.make(url, pages: pages)
        return url
    }

    @Test func aPileIsReadOneDocumentAtATime() async throws {
        let pages = ["ACME POWER\nPage 1 of 2", "ACME POWER\nPage 2 of 2", "CORNER HARDWARE\nReceipt"]
        let reader = ScriptedBoundaryReader { _ in [1, 3] }
        let analysis = await BoundaryFindingAnalyzer(reader).analyze(ocrText: TextRecognizer.joined(pages), pageCount: 3,
                                                                       pdf: try scan(pages))
        #expect(analysis.error == nil)
        #expect(analysis.documents.map { $0.firstPage...$0.lastPage } == [1...2, 3...3])
        #expect(analysis.documents.map(\.facets.vendor) == ["ACME POWER", "CORNER HARDWARE"])
        #expect(reader.read == [2, 1])
        #expect(analysis.summary.hasPrefix("Found 2 documents"))
    }

    @Test func aReaderThatSplitsAPartIsOverruled() async throws {
        let pages = ["NORTHWIND\nInvoice 4471", "NORTHWIND\nPayment receipt for invoice 4471"]
        let reader = ScriptedBoundaryReader(splitsParts: true) { _ in [1] }
        let analysis = await BoundaryFindingAnalyzer(reader).analyze(ocrText: TextRecognizer.joined(pages), pageCount: 2,
                                                                       pdf: try scan(pages))
        #expect(analysis.documents.map { $0.firstPage...$0.lastPage } == [1...2])
        #expect(analysis.documents.first?.confidence == 0.8)
    }

    @Test func aReaderThatCantAnswerReadsTheWholeScan() async throws {
        let pages = ["ACME POWER", "CORNER HARDWARE"]
        let reader = ScriptedBoundaryReader { _ in nil }
        let analysis = await BoundaryFindingAnalyzer(reader).analyze(ocrText: TextRecognizer.joined(pages), pageCount: 2,
                                                                       pdf: try scan(pages))
        #expect(reader.read == [2])
        #expect(analysis.documents.count == 1)
    }

    @Test func onlyAppleFindsBoundariesFirst() {
        var settings = HomeClerkSettings(values: ["basepath": .string(temp.url.path)])
        settings.appleModel = "on-device"
        let apple = HomeClerkPipeline.analyzer(.apple, settings: settings, taxonomy: TestData.taxonomy, profile: .empty, ledger: nil)
        let ollama = HomeClerkPipeline.analyzer(.ollama, settings: settings, taxonomy: TestData.taxonomy, profile: .empty, ledger: nil)
        #expect(apple is BoundaryFindingAnalyzer)
        #expect(ollama is OllamaFacetAnalyzer)
    }

    @Test func aBillFollowedByTheReceiptForPayingItIsOneDocument() {
        func doc(_ first: Int, _ last: Int, _ type: String, _ vendor: String, _ amount: Decimal?) -> FacetDocument {
            FacetDocument(firstPage: first, lastPage: last,
                          facets: DocumentFacets(documentType: type, area: "Devices", vendor: vendor, amount: amount), confidence: 0.9)
        }
        let paid = RelatedDocuments.merged(FacetAnalysis(documents: [
            doc(1, 1, "Bill", "Northwind_Electronics", 219.99), doc(2, 2, "Receipt", "Northwind Electronics", 219.99),
            doc(3, 3, "Bill", "Acme_Power", 52.18)]))
        #expect(paid.documents.map { $0.firstPage...$0.lastPage } == [1...2, 3...3])
        #expect(paid.documents.first?.facets.documentType == "Receipt")

        // A different amount, another vendor, the wrong order, or a gap between them: kept apart
        for documents in [[doc(1, 1, "Bill", "Acme", 52.18), doc(2, 2, "Receipt", "Acme", 48.00)],
                          [doc(1, 1, "Bill", "Acme", 52.18), doc(2, 2, "Receipt", "Corner_Hardware", 52.18)],
                          [doc(1, 1, "Receipt", "Acme", 52.18), doc(2, 2, "Bill", "Acme", 52.18)],
                          [doc(1, 1, "Bill", "Acme", 52.18), doc(3, 3, "Receipt", "Acme", 52.18)],
                          [doc(1, 1, "Bill", "Acme", nil), doc(2, 2, "Receipt", "Acme", nil)]] {
            #expect(RelatedDocuments.merged(FacetAnalysis(documents: documents)).documents.count == 2)
        }
    }
}
