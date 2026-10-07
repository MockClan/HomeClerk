import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import HomeClerkKit

@Suite struct PageRendererTests {
    /// A one-page US Letter PDF with a black square in its bottom-left corner, optionally flagged as rotated.
    static func pdf(rotation: Int, cropBox: CGRect? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rot-\(UUID()).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.fill(CGRect(x: 100, y: 100, width: 20, height: 20))
        context.endPDFPage()
        context.closePDF()
        if rotation != 0 || cropBox != nil {
            let document = PDFDocument(url: url)!
            document.page(at: 0)!.rotation = rotation
            if let cropBox { document.page(at: 0)!.setBounds(cropBox, for: .cropBox) }
            document.write(to: url)
        }
        return url
    }

    /// Whether the pixel at (x, y), measured from the image's top-left, is dark.
    static func isDark(_ image: CGImage, _ x: Int, _ y: Int) -> Bool {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Draw so that image pixel (x, y) lands on the 1×1 context
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return pixel[0] < 128
    }

    @Test func uprightPageKeepsItsShapeAndCorners() throws {
        let url = try Self.pdf(rotation: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try #require(try PageRenderer.images(of: url, dpi: 72).first)
        #expect(image.width == 612 && image.height == 792)
        #expect(Self.isDark(image, 10, 782))      // bottom-left
        #expect(!Self.isDark(image, 10, 10))      // top-left
    }

    @Test func rotatedPageIsRenderedUpright() throws {
        let url = try Self.pdf(rotation: 90)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try #require(try PageRenderer.images(of: url, dpi: 72).first)
        // Turned a quarter clockwise: landscape, and the bottom-left square moves to the top-left
        #expect(image.width == 792 && image.height == 612)
        #expect(Self.isDark(image, 10, 10))
        #expect(!Self.isDark(image, 10, 602))
    }

    @Test func onlyTheCropBoxIsRendered() throws {
        let url = try Self.pdf(rotation: 0, cropBox: CGRect(x: 100, y: 100, width: 412, height: 592))
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try #require(try PageRenderer.images(of: url, dpi: 72).first)
        #expect(image.width == 412 && image.height == 592)
        // The small square at (100, 100) is the crop box's bottom-left corner; the big one is cropped away
        #expect(Self.isDark(image, 5, 586))
        #expect(!Self.isDark(image, 30, 560))
    }
}
