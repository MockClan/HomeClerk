import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import HomeClerkKit

/// A temporary folder removed when the test ends.
final class TempFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("homeclerk-\(UUID().uuidString)")
    init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }
    func file(_ name: String, _ text: String = "x") throws -> URL {
        let file = url.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}

/// PDFs for tests: pages of drawn text, as vector text or as a scanned-style image.
enum TestPDF {
    static func make(_ url: URL, pages: [String], asImage: Bool = false) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for text in pages {
            context.beginPDFPage(nil)
            if asImage {
                context.draw(image(of: text), in: box)
            } else {
                draw(text, in: context, scale: 1)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// The text rendered at 200 DPI, like a scan.
    static func image(of text: String) -> CGImage {
        let scale: CGFloat = 200 / 72
        let context = CGContext(data: nil, width: Int(612 * scale), height: Int(792 * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 612 * scale, height: 792 * scale))
        draw(text, in: context, scale: scale)
        return context.makeImage()!
    }

    static func draw(_ text: String, in context: CGContext, scale: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 24 * scale, nil)
        for (i, line) in text.split(separator: "\n").enumerated() {
            let attributed = NSAttributedString(string: String(line), attributes: [.init(kCTFontAttributeName as String): font])
            context.textPosition = CGPoint(x: 72 * scale, y: (700 - CGFloat(i) * 40) * scale)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
    }
}

@Suite struct FileOrganizerTests {
    @Test func movesIntoTheFolderAndAvoidsOverwriting() throws {
        let temp = TempFolder()
        let organizer = FileOrganizer(outbox: temp.url.appendingPathComponent("Organized"))
        let first = try organizer.organize(try temp.file("a.pdf"), folder: "Bills - Utilities", filename: "2026-02-03-Acme_Power-Electric_Bill.pdf")
        let second = try organizer.organize(try temp.file("b.pdf"), folder: "Bills - Utilities", filename: "2026-02-03-Acme_Power-Electric_Bill.pdf")
        #expect(first.lastPathComponent == "2026-02-03-Acme_Power-Electric_Bill.pdf")
        #expect(second.lastPathComponent == "2026-02-03-Acme_Power-Electric_Bill_2.pdf")
        #expect(first.deletingLastPathComponent().lastPathComponent == "Bills - Utilities")
    }

    @Test func fixesUnusableNames() throws {
        let temp = TempFolder()
        let organizer = FileOrganizer(outbox: temp.url)
        #expect(try organizer.organize(try temp.file("a.pdf"), folder: "X", filename: "a/b name").lastPathComponent == "a_b_name.pdf")
        #expect(try organizer.organize(try temp.file("b.pdf"), folder: "X", filename: ".pdf").lastPathComponent.hasPrefix("document_"))
    }
}

@Suite struct IndexAndReviewTests {
    @Test func indexAppendsAndReadsTheFormatTheCurrentAppWrites() throws {
        let temp = TempFolder()
        let url = temp.url.appendingPathComponent("index.jsonl")
        try #"{"filed_at":"2026-02-03T09:15:00.1234567-07:00","path":"/x/Bills - Utilities/a.pdf","source":"scan.pdf","pages":[1,1],"model":"Claude claude-sonnet-5-5","confidence":0.95,"summary":"A bill.","facets":{"document_type":"Bill","area":"Utilities","tags":[],"vendor":"Acme_Power","description":"Electric_Bill","document_date":"2026-02-03","due_date":"","expires_on":"","amount":88.12,"person":"","vehicle":"","pet":""}}"#
            .appending("\n").write(to: url, atomically: true, encoding: .utf8)
        let index = DocumentIndex(url: url)
        try index.append(DocumentIndex.Entry(path: "/x/b.pdf", source: "scan2.pdf", pages: [1, 2], model: "Ollama m",
                                             confidence: 0.9, summary: "s", facets: DocumentFacets(vendor: "Acme")))
        let entries = index.load()
        #expect(entries.count == 2)
        #expect(entries[0].facets.amount == Decimal(string: "88.12"))
        #expect(entries[1].pages == [1, 2] && entries[1].facets.vendor == "Acme")
    }

    @Test func proposalRoundTripsAndSidecarsAreRemoved() throws {
        let temp = TempFolder()
        let scan = try temp.file("scan.pdf")
        var analysis = FacetAnalysis(documents: [FacetDocument(firstPage: 1, lastPage: 2,
                                                               facets: DocumentFacets(vendor: "Acme", amount: Decimal(string: "12.50")),
                                                               confidence: 0.6)], summary: "Unsure.")
        analysis.model = "Ollama m"
        try ReviewProposal.save(analysis, for: scan)
        try "why".write(to: ReviewProposal.reasonURL(for: scan), atomically: true, encoding: .utf8)
        #expect(ReviewProposal.proposalURL(for: scan).lastPathComponent == "scan.proposal.json")
        let loaded = try #require(ReviewProposal.load(for: scan))
        #expect(loaded.documents == analysis.documents && loaded.summary == "Unsure." && loaded.model == "Ollama m")
        ReviewProposal.deleteSidecars(for: scan)
        #expect(!FileManager.default.fileExists(atPath: ReviewProposal.reasonURL(for: scan).path))
    }
}

@Suite struct PDFToolsTests {
    @Test func splitsPageRanges() throws {
        let temp = TempFolder()
        let source = temp.url.appendingPathComponent("three.pdf")
        try TestPDF.make(source, pages: ["One", "Two", "Three"])
        let output = temp.url.appendingPathComponent("out/two-three.pdf")
        try PDFTools.split(source, pages: 2...3, to: output)
        #expect(PDFDocument(url: output)?.pageCount == 2)
        #expect(PDFDocument(url: output)?.page(at: 0)?.string?.contains("Two") == true)
        #expect(throws: (any Error).self) { try PDFTools.split(source, pages: 5...6, to: output) }
    }

    @Test func detectsAnUnfinishedScan() throws {
        let temp = TempFolder()
        let complete = temp.url.appendingPathComponent("done.pdf")
        try TestPDF.make(complete, pages: ["Done"])
        #expect(PDFTools.endsWithEOFMarker(complete))
        let partial = try temp.file("partial.pdf", "%PDF-1.7\n1 0 obj << >> endobj\n")
        #expect(!PDFTools.endsWithEOFMarker(partial))
    }

    @Test func waitsForAStableCompleteFile() async throws {
        let temp = TempFolder()
        let file = temp.url.appendingPathComponent("scan.pdf")
        try TestPDF.make(file, pages: ["Done"])
        // Returns as soon as the file is stable; the generous limit only matters on a busy machine
        // (CI, or other tests' OCR holding the shared threads), where waking from a pause can lag
        #expect(await PDFTools.waitUntilComplete(file, pollInterval: .milliseconds(20), maxWait: .seconds(30)))
        let partial = try temp.file("partial.pdf", "%PDF-1.7 still writing")
        #expect(!(await PDFTools.waitUntilComplete(partial, pollInterval: .milliseconds(20), maxWait: .milliseconds(200))))
    }
}

@Suite(.serialized) struct FinisherTests {
    @Test(.requiresOCR) func scannedPDFBecomesSearchableAndIsTagged() async throws {
        let temp = TempFolder()
        let pdf = temp.url.appendingPathComponent("scan.pdf")
        try TestPDF.make(pdf, pages: ["ACME POWER ELECTRIC BILL\nAMOUNT DUE 88.12"], asImage: true)
        #expect(Finisher.text(of: pdf).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let finisher = Finisher(makeSearchable: true, applyTags: true, createReminders: false, remindersList: "x",
                                expirationLeadDays: 30)
        await finisher.finish(pdf, facets: DocumentFacets(documentType: "Bill", area: "Utilities", tags: ["utilities"],
                                                          vendor: "Acme_Power"), today: "2026-04-01")
        #expect(Finisher.text(of: pdf).uppercased().contains("ACME POWER"))
        let tags = try pdf.resourceValues(forKeys: [.tagNamesKey]).tagNames
        #expect(tags == ["Utilities"])
    }

    @Test func pdfsThatAlreadyHaveTextAreLeftAlone() throws {
        let temp = TempFolder()
        let pdf = temp.url.appendingPathComponent("text.pdf")
        try TestPDF.make(pdf, pages: ["This page already has plenty of selectable text on it"])
        let before = try Data(contentsOf: pdf)
        try Searchable.addTextLayer(to: pdf)
        #expect(try Data(contentsOf: pdf) == before)
    }

    @Test(.requiresOCR) func mixedPDFSearchesScannedPagesAndRetainsExistingPages() throws {
        let temp = TempFolder()
        let pdf = temp.url.appendingPathComponent("mixed.pdf")
        let scan = temp.url.appendingPathComponent("image.pdf")
        try TestPDF.make(pdf, pages: ["Existing selectable invoice text stays on this page", "7"])
        try TestPDF.make(scan, pages: ["SCANNED ELECTRIC BILL\nACCOUNT BALANCE 88.12", "SCANNED RECEIPT\nPAYMENT CONFIRMED"], asImage: true)
        let document = try #require(PDFDocument(url: pdf))
        let images = try #require(PDFDocument(url: scan))
        let first = try #require(document.page(at: 0))
        let link = PDFAnnotation(bounds: CGRect(x: 72, y: 690, width: 240, height: 30), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.test/invoice")
        first.addAnnotation(link)
        document.insert(try #require(images.page(at: 0)), at: 1)
        document.insert(try #require(images.page(at: 1)), at: 3)
        #expect(document.write(to: pdf))
        let expectedText = first.string
        let shortText = document.page(at: 2)?.string
        let originalCG = try #require(CGPDFDocument(pdf as CFURL))
        let originalImagePage = try #require(originalCG.page(at: 2))
        let originalPixels = try #require(Searchable.render(originalImagePage, box: originalImagePage.getBoxRect(.mediaBox), dpi: 72)?.dataProvider?.data)

        try Searchable.addTextLayer(to: pdf)
        let output = try #require(PDFDocument(url: pdf))
        #expect(output.pageCount == 4)
        #expect(output.page(at: 0)?.string == expectedText)
        #expect(output.page(at: 0)?.annotations.first?.url == link.url)
        #expect(output.page(at: 1)?.string?.uppercased().contains("SCANNED ELECTRIC BILL") == true)
        #expect(output.page(at: 2)?.string == shortText)
        #expect(output.page(at: 3)?.string?.uppercased().contains("PAYMENT CONFIRMED") == true)
        let outputCG = try #require(CGPDFDocument(pdf as CFURL))
        let outputImagePage = try #require(outputCG.page(at: 2))
        let outputPixels = try #require(Searchable.render(outputImagePage, box: outputImagePage.getBoxRect(.mediaBox), dpi: 72)?.dataProvider?.data)
        #expect(originalPixels as Data == outputPixels as Data)
        let beforeRepeat = try Data(contentsOf: pdf)
        try Searchable.addTextLayer(to: pdf)
        #expect(try Data(contentsOf: pdf) == beforeRepeat)
    }

    @Test(.requiresOCR) func rotatedScanRetainsPageGeometryAndAnnotations() throws {
        let temp = TempFolder()
        let pdf = temp.url.appendingPathComponent("rotated.pdf")
        try TestPDF.make(pdf, pages: ["ROTATED SCANNED INVOICE\nTOTAL AMOUNT 42.00"], asImage: true)
        let document = try #require(PDFDocument(url: pdf))
        let page = try #require(document.page(at: 0))
        let crop = CGRect(x: 20, y: 30, width: 560, height: 720)
        page.setBounds(crop, for: .cropBox)
        page.rotation = 90
        let note = PDFAnnotation(bounds: CGRect(x: 60, y: 60, width: 30, height: 30), forType: .text, withProperties: nil)
        note.contents = "Keep this note"
        page.addAnnotation(note)
        #expect(document.write(to: pdf))
        let original = try #require(PDFDocument(url: pdf)?.page(at: 0))
        let media = original.bounds(for: .mediaBox)
        let originalCrop = original.bounds(for: .cropBox)
        let originalNoteBounds = original.annotations.first?.bounds
        try Searchable.addTextLayer(to: pdf)
        let output = try #require(PDFDocument(url: pdf)?.page(at: 0))
        #expect(output.string?.uppercased().contains("ROTATED SCANNED INVOICE") == true)
        #expect(output.rotation == 90)
        #expect(output.bounds(for: .mediaBox) == media)
        #expect(output.bounds(for: .cropBox) == originalCrop)
        #expect(output.annotations.first?.contents == "Keep this note")
        #expect(output.annotations.first?.bounds == originalNoteBounds)
    }

    @Test func oversizedPageFailureDoesNotRewriteOriginal() throws {
        let temp = TempFolder()
        let pdf = temp.url.appendingPathComponent("oversized.pdf")
        var box = CGRect(x: 0, y: 0, width: 100_000, height: 100_000)
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let before = try Data(contentsOf: pdf)
        #expect(throws: Searchable.Failure.self) { try Searchable.addTextLayer(to: pdf) }
        #expect(try Data(contentsOf: pdf) == before)
    }

    @Test func shortSelectableTextIsNotDuplicatedOrRewritten() throws {
        let temp = TempFolder()
        let pdf = temp.url.appendingPathComponent("short.pdf")
        try TestPDF.make(pdf, pages: ["2026"])
        let before = try Data(contentsOf: pdf)
        try Searchable.addTextLayer(to: pdf)
        #expect(try Data(contentsOf: pdf) == before)
    }

    @Test(.requiresOCR) func blankPageWithoutRecognizedTextIsNotRewritten() throws {
        let temp = TempFolder()
        let pdf = temp.url.appendingPathComponent("blank.pdf")
        try TestPDF.make(pdf, pages: [""])
        let before = try Data(contentsOf: pdf)
        try Searchable.addTextLayer(to: pdf)
        #expect(try Data(contentsOf: pdf) == before)
    }

    @Test func nonzeroOriginIsRetainedRatherThanNormalizedByPDFKit() throws {
        let temp = TempFolder()
        let pdf = temp.url.appendingPathComponent("offset.pdf")
        var box = CGRect(x: 40, y: 60, width: 612, height: 792)
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.draw(TestPDF.image(of: "OFFSET SCANNED INVOICE"), in: box)
        context.endPDFPage()
        context.closePDF()
        let before = try Data(contentsOf: pdf)
        #expect(throws: Searchable.Failure.self) { try Searchable.addTextLayer(to: pdf) }
        #expect(try Data(contentsOf: pdf) == before)
    }
}
