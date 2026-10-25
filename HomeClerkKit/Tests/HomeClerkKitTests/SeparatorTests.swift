import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import HomeClerkKit

/// Blank pages and sheets between documents scanned as one pile.
@Suite struct SeparatorTests {
    let temp = TempFolder()

    @Test func blankPagesSeparateSingleSidedScans() {
        // text, blank, text, text, blank, text
        let blank = [false, true, false, false, true, false]
        #expect(Separators.sections(blank: blank, mode: .blankPage) == [[1], [3, 4], [6]])
        #expect(Separators.sections(blank: [true, false, false, true], mode: .blankPage) == [[2, 3]])
        #expect(Separators.sections(blank: [true, true], mode: .blankPage).isEmpty)
        #expect(Separators.sections(blank: blank, mode: .none) == [[1, 2, 3, 4, 5, 6]])
    }

    @Test func blankSheetsSeparateDoubleSidedScansAndDropBlankBacks() {
        // Sheet 1: letter + blank back. Sheet 2: both sides blank (separator).
        // Sheet 3: two-sided statement. Sheet 4: receipt + blank back.
        let blank = [false, true, true, true, false, false, false, true]
        #expect(Separators.sections(blank: blank, mode: .blankSheet) == [[1], [5, 6, 7]])
        // A blank page that isn't a whole sheet doesn't separate in this mode
        #expect(Separators.sections(blank: [false, true, false, false], mode: .blankSheet) == [[1, 3, 4]])
        // An odd last page that's blank is just dropped
        #expect(Separators.sections(blank: [false, false, true], mode: .blankSheet) == [[1, 2]])
    }

    @Test func onlyEmptyPagesCountAsBlank() {
        func canvas(_ draw: (CGContext) -> Void) -> CGImage {
            let context = CGContext(data: nil, width: 425, height: 550, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.setFillColor(gray: 0.97, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 425, height: 550))
            draw(context)
            return context.makeImage()!
        }
        // A scanned blank page: a few specks, and a shadow along the edge
        let empty = canvas { c in
            c.setFillColor(gray: 0.2, alpha: 1)
            for i in 0..<6 { c.fill(CGRect(x: 60 + i * 50, y: 90 + i * 60, width: 2, height: 2)) }
            c.fill(CGRect(x: 0, y: 0, width: 12, height: 550))
        }
        #expect(Separators.isBlank(empty, text: ""))
        #expect(!Separators.isBlank(empty, text: "Notes for the trip"))
        // A photo or drawing with no text isn't blank
        let photo = canvas { c in c.setFillColor(gray: 0.3, alpha: 1); c.fill(CGRect(x: 80, y: 120, width: 260, height: 200)) }
        #expect(!Separators.isBlank(photo, text: ""))
        #expect(!Separators.isBlank(TestPDF.image(of: DocumentProcessorTests.billText), text: ""))
    }

    @Test func pagesAreNumberedForTheReaderAndReadBack() {
        let pages = ["ACME POWER\nStatement", "", "Page two of the receipt"]
        let joined = TextRecognizer.joined(pages)
        #expect(joined.hasPrefix("--- Page 1 of 3 ---\nACME POWER"))
        #expect(joined.contains("\n\n--- Page 3 of 3 ---\nPage two of the receipt"))
        #expect(TextRecognizer.pages(of: joined) == pages)
        // OCR text saved by earlier versions, between unnumbered page breaks
        #expect(TextRecognizer.pages(of: "first\n--- Page Break ---\n\nsecond") == ["first", "second"])
    }

    @Test(.requiresOCR) func aPileIsSeparatedIntoScansBackInTheInbox() async throws {
        var settings = HomeClerkSettings(values: ["basepath": .string(temp.url.path)])
        settings.scanSeparator = .blankPage
        settings.preserveOriginals = false
        try FileManager.default.createDirectory(at: settings.inboxFolder, withIntermediateDirectories: true)
        let pile = settings.inboxFolder.appendingPathComponent("pile.pdf")
        try TestPDF.make(pile, pages: [DocumentProcessorTests.billText, "", "CORNER HARDWARE\nRECEIPT\nTotal 18.40\n"])
        let events = Locked<[PipelineEvent]>([])
        let processor = DocumentProcessor(settings: settings, taxonomy: TestData.taxonomy,
            analyzer: FakeAnalyzer("Fake", .init(documents: [DocumentProcessorTests.bill()])),
            duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder),
            index: DocumentIndex(url: temp.url.appendingPathComponent(DocumentIndex.fileName)),
            finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "x",
                               expirationLeadDays: 30),
            events: { event in events.mutate { $0.append(event) } }, today: { "2026-01-01" })
        await processor.process(pile)

        let parts = try FileManager.default.contentsOfDirectory(atPath: settings.inboxFolder.path).sorted()
        #expect(parts == ["pile part 1 of 2.pdf", "pile part 2 of 2.pdf"])
        #expect(parts.map { PDFDocument(url: settings.inboxFolder.appendingPathComponent($0))?.pageCount } == [1, 1])
        #expect(events.value.contains(.separated(source: pile, parts: 2)))
        #expect(!events.value.contains { if case .filed = $0 { true } else { false } })
    }
}
