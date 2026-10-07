import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import HomeClerkKit

@Suite struct LockedPDFTests {
    let temp = TempFolder()

    func lockedPDF(password: String) throws -> URL {
        try Self.make(temp.url.appendingPathComponent("locked.pdf"), password: password)
    }

    /// A one-page PDF with a line of text, needing `password` to open.
    @discardableResult
    static func make(_ url: URL, password: String) throws -> URL {
        let info = [kCGPDFContextUserPassword: password, kCGPDFContextOwnerPassword: password + "-owner"] as CFDictionary
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, info))
        context.beginPage(mediaBox: &box)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Statement for Jane Smith"))
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPage()
        context.closePDF()
        return url
    }

    @Test func detectsAndUnlocksWithTheRightPassword() throws {
        let url = try lockedPDF(password: "maple-42")
        #expect(PDFTools.isLocked(url))

        #expect(throws: (any Error).self) { try PDFTools.unlock(url, password: "wrong") }
        #expect(PDFTools.isLocked(url))

        try PDFTools.unlock(url, password: "maple-42")
        #expect(!PDFTools.isLocked(url))
        let text = try #require(PDFDocument(url: url)?.string)
        #expect(text.contains("Jane Smith"))
    }

    @Test func anOrdinaryPDFIsntLocked() throws {
        let url = try PageRendererTests.pdf(rotation: 0)
        #expect(!PDFTools.isLocked(url))
        try PDFTools.unlock(url, password: "anything")   // nothing to do
        #expect(!PDFTools.isLocked(url))
    }
}
