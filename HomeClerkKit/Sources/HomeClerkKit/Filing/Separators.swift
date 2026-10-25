import CoreGraphics
import Foundation
import PDFKit

/// Blank pages or sheets put between documents scanned as one pile. A scan is cut at them into
/// sections, each read on its own; the reader may still split a section further.
public enum Separators {
    /// Pages are checked for ink at this resolution: enough to see a line of text, cheap to render.
    static let dpi = 50

    /// Blank: no text found, and next to no ink away from the edges (where scanners leave shadows).
    /// Both must hold, so a page that's only a photo, a drawing, or a signature isn't taken for one.
    public static func isBlank(_ image: CGImage, text: String) -> Bool {
        text.filter { !$0.isWhitespace }.count <= 3 && inkCoverage(image) < 0.003
    }

    /// The share of dark pixels inside a 6% margin.
    static func inkCoverage(_ image: CGImage) -> Double {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return 1 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let marginX = width * 6 / 100, marginY = height * 6 / 100
        var dark = 0, counted = 0
        for y in marginY..<(height - marginY) {
            for x in marginX..<(width - marginX) {
                counted += 1
                if pixels[y * width + x] < 160 { dark += 1 }
            }
        }
        return counted == 0 ? 1 : Double(dark) / Double(counted)
    }

    /// The scan's sections as 1-based page numbers, separators left out. With blank sheets, a sheet
    /// (pages 1–2, 3–4, …) blank on both sides separates; any other blank page is the back of a
    /// single-sided page and is dropped. Empty when every page is blank.
    public static func sections(blank: [Bool], mode: ScanSeparator) -> [[Int]] {
        guard !blank.isEmpty else { return [] }
        let pages = Array(1...blank.count)
        switch mode {
        case .none:
            return [pages]
        case .blankPage:
            return pages.split(whereSeparator: { blank[$0 - 1] }).map(Array.init)
        case .blankSheet:
            var sections: [[Int]] = [[]]
            for sheet in stride(from: 1, through: blank.count, by: 2) {
                let sides = [sheet, sheet + 1].filter { $0 <= blank.count }
                if sides.count == 2, sides.allSatisfy({ blank[$0 - 1] }) {
                    sections.append([])
                } else {
                    sections[sections.count - 1] += sides.filter { !blank[$0 - 1] }
                }
            }
            return sections.filter { !$0.isEmpty }
        }
    }

    /// Writes each section of `pdf` as its own PDF in `folder`, named after the scan with the
    /// section's place ("statement part 2 of 3.pdf"). Returns them in order.
    public static func write(_ sections: [[Int]], of pdf: URL, to folder: URL) throws -> [URL] {
        guard let source = PDFDocument(url: pdf) else { throw PDFTools.Failure("The scan couldn't be opened to separate it.") }
        let stem = pdf.deletingPathExtension().lastPathComponent
        return try sections.enumerated().map { index, pages in
            let part = PDFDocument()
            for number in pages {
                guard let page = source.page(at: number - 1)?.copy() as? PDFPage else {
                    throw PDFTools.Failure("Page \(number) of the scan couldn't be copied.")
                }
                part.insert(page, at: part.pageCount)
            }
            guard let data = part.dataRepresentation() else { throw PDFTools.Failure("A section of the scan couldn't be saved.") }
            let name = sections.count == 1 ? "\(stem) without blank pages" : "\(stem) part \(index + 1) of \(sections.count)"
            let url = FileOrganizer.unique(folder.appendingPathComponent("\(name).pdf"))
            try PrivateFile.write(data, to: url)
            return url
        }
    }
}
