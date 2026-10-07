import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Renders PDF pages to images with PDFKit.
public enum PageRenderer {
    /// OCR wants 300 DPI; vision models need far less.
    public static let ocrDPI = 300
    public static let modelDPI = 110

    public struct RenderError: Error, CustomStringConvertible {
        public let description: String
    }

    public static func pageCount(of pdf: URL) throws -> Int {
        guard let document = PDFDocument(url: pdf) else { throw RenderError(description: "can't open \(pdf.lastPathComponent) as a PDF") }
        return document.pageCount
    }

    public static func open(_ pdf: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: pdf) else { throw RenderError(description: "can't open \(pdf.lastPathComponent) as a PDF") }
        return document
    }

    /// Each page as a CGImage on a white background, in page order. Holds every page in memory;
    /// for OCR at 300 DPI use `image(of:page:dpi:)` one page at a time instead.
    public static func images(of pdf: URL, dpi: Int = ocrDPI, limit: Int = .max) throws -> [CGImage] {
        let document = try open(pdf)
        return try (0..<min(document.pageCount, limit)).map { try image(of: document, page: $0, dpi: dpi) }
    }

    /// One page (0-based) as a CGImage on a white background.
    public static func image(of document: PDFDocument, page index: Int, dpi: Int) throws -> CGImage {
        let scale = CGFloat(dpi) / 72
        do {
            guard let page = document.page(at: index) else { throw RenderError(description: "page \(index + 1) is missing") }
            // The visible page: the crop box, turned by the page's rotation (scanners sometimes
            // save a page sideways with a rotation flag rather than rotating the image)
            let bounds = page.bounds(for: .cropBox)
            let turned = abs(page.rotation) % 180 == 90
            let size = turned ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
            let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw RenderError(description: "can't render page \(index + 1)") }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            // draw(with:to:) applies the page's rotation and crop itself
            page.draw(with: .cropBox, to: context)
            guard let image = context.makeImage() else { throw RenderError(description: "can't render page \(index + 1)") }
            return image
        }
    }

    /// Each page as PNG data.
    public static func pngs(of pdf: URL, dpi: Int, limit: Int = .max) throws -> [Data] {
        try images(of: pdf, dpi: dpi, limit: limit).map(png)
    }

    public static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError(description: "can't encode PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError(description: "can't encode PNG") }
        return data as Data
    }
}
