import Foundation
import PDFKit

/// Splitting scans and checking that the scanner has finished writing them.
public enum PDFTools {
    /// Writes pages `first...last` (1-based) of `source` to a new PDF at `output`.
    public static func split(_ source: URL, pages: ClosedRange<Int>, to output: URL) throws {
        guard let document = PDFDocument(url: source) else { throw Failure("can't open \(source.lastPathComponent) as a PDF") }
        let extracted = PDFDocument()
        for number in pages where number >= 1 && number <= document.pageCount {
            if let page = document.page(at: number - 1)?.copy() as? PDFPage {
                extracted.insert(page, at: extracted.pageCount)
            }
        }
        guard extracted.pageCount > 0 else { throw Failure("no valid pages \(pages) in \(source.lastPathComponent)") }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard extracted.write(to: output) else { throw Failure("couldn't write \(output.lastPathComponent)") }
    }

    /// Turns pages using PDF rotation metadata, retaining page content and coordinates.
    /// `pages` are 0-based; nil turns every page. A verified original is kept before rewriting.
    public static func rotate(_ url: URL, pages: Set<Int>?, quarterTurns: Int) throws {
        let original = try PDFTransformation.readOriginal(url)
        guard let document = PDFDocument(data: original), !document.isLocked, document.pageCount > 0,
              let provider = CGDataProvider(data: original as CFData),
              let source = CGPDFDocument(provider) else { throw Failure("can't open \(url.lastPathComponent) as a PDF") }
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return }
        if let pages, pages.contains(where: { $0 < 0 || $0 >= document.pageCount }) {
            throw Failure("The selected page is no longer in this PDF.")
        }
        guard pages == nil || pages?.isEmpty == false else { return }
        try PDFTransformation.requireNoForms(source, document: document)
        // Materialize PDFKit's lazily loaded outline before serialization.
        let outline = document.outlineRoot
        document.outlineRoot = outline
        for index in 0..<document.pageCount where pages?.contains(index) ?? true {
            guard let page = document.page(at: index) else { throw Failure("can't read every page") }
            page.rotation = ((page.rotation + turns * 90) % 360 + 360) % 360
        }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".homeclerk_rotate_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let output = document.dataRepresentation() else { throw Failure("can't create the rotated PDF") }
        try PrivateFile.write(output, to: temp)
        guard let verified = PDFDocument(url: temp), verified.pageCount == document.pageCount else {
            throw Failure("can't verify the rotated PDF")
        }
        for index in 0..<document.pageCount {
            guard let expected = document.page(at: index), let actual = verified.page(at: index),
                  expected.string == actual.string, expected.rotation == actual.rotation,
                  expected.annotations.count == actual.annotations.count,
                  [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox].allSatisfy({
                      expected.bounds(for: $0) == actual.bounds(for: $0)
                  }) else { throw Failure("The rotated PDF did not retain every page's text and geometry.") }
        }
        try PDFTransformation.replace(url, with: temp, original: original, operation: "rotation")
    }

    /// What Review shows for a scan that needs a password to open.
    public static let lockedReason = "Password protected. Enter its password in Review to unlock it, then HomeClerk reads it again."

    /// Needs a password to open. (A password that only restricts printing or copying doesn't count;
    /// those open and read normally.)
    public static func isLocked(_ url: URL) -> Bool { PDFDocument(url: url)?.isLocked ?? false }

    /// Opens a password-protected PDF and rewrites it without the password, so it can be read,
    /// filed, and opened later without asking. The password isn't kept anywhere. Pages are redrawn
    /// into a new PDF (PDFKit would save the encryption back); their text stays selectable.
    /// The encrypted original is always kept. Links, annotations, and outlines may be removed;
    /// interactive forms/signature fields are refused.
    public static func unlock(_ url: URL, password: String) throws {
        let original = try PDFTransformation.readOriginal(url)
        guard let provider = CGDataProvider(data: original as CFData),
              let source = CGPDFDocument(provider) else { throw Failure("can't open \(url.lastPathComponent) as a PDF") }
        guard !source.isUnlocked else { return }
        guard source.unlockWithPassword(password) else { throw Failure("That password didn't open it.") }
        guard let document = PDFDocument(data: original), document.unlock(withPassword: password) else {
            throw Failure("can't verify the unlocked source")
        }
        try PDFTransformation.requireNoForms(source, document: document)
        try redraw(source, replacing: url, original: original, expected: document)
    }

    /// Draws unlocked pages upright. Publish only after validating page count, geometry and text;
    /// keep the encrypted source separately because redrawing does not retain all PDF structure.
    private static func redraw(_ source: CGPDFDocument, replacing url: URL, original: Data, expected: PDFDocument) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".homeclerk_redraw_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard source.numberOfPages > 0 else { throw Failure("The PDF has no pages.") }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw Failure("can't write \(url.lastPathComponent)") }
        for number in 1...source.numberOfPages {
            try Task.checkCancellation()
            guard let page = source.page(at: number) else { throw Failure("can't read every page") }
            let box = page.getBoxRect(.cropBox)
            guard box.minX.isFinite, box.minY.isFinite, box.width.isFinite, box.height.isFinite,
                  box.width > 0, box.height > 0 else { throw Failure("The PDF has invalid page geometry.") }
            let angle = (Int(page.rotationAngle) % 360 + 360) % 360
            var out = angle % 180 == 0 ? CGRect(origin: .zero, size: box.size)
                                       : CGRect(x: 0, y: 0, width: box.height, height: box.width)
            context.beginPage(mediaBox: &out)
            context.saveGState()
            context.translateBy(x: out.width / 2, y: out.height / 2)
            context.rotate(by: -CGFloat(angle) * .pi / 180)   // clockwise, in PDF's y-up space
            context.translateBy(x: -box.midX, y: -box.midY)
            context.clip(to: box)
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPage()
        }
        context.closePDF()
        try PrivateFile.write(data as Data, to: temp)
        guard let verified = PDFDocument(url: temp), !verified.isLocked,
              verified.pageCount == source.numberOfPages else { throw Failure("can't verify the unlocked PDF") }
        for index in 0..<expected.pageCount {
            guard let before = expected.page(at: index), let after = verified.page(at: index) else {
                throw Failure("The unlocked PDF lost a page.")
            }
            let turned = abs(before.rotation) % 180 == 90
            let crop = before.bounds(for: .cropBox).size
            let size = turned ? CGSize(width: crop.height, height: crop.width) : crop
            let words: (String?) -> [String] = { ($0 ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init) }
            guard after.bounds(for: .mediaBox).size == size, words(before.string) == words(after.string) else {
                throw Failure("The unlocked PDF did not retain every page's text and geometry. The original was left unchanged.")
            }
        }
        try PDFTransformation.replace(url, with: temp, original: original, operation: "unlocking")
    }

    /// A complete PDF ends with %%EOF, optionally followed by whitespace.
    public static func endsWithEOFMarker(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return false }
        let tailLength = min(UInt64(1024), size)
        try? handle.seek(toOffset: size - tailLength)
        guard let tail = try? handle.read(upToCount: Int(tailLength)),
              let marker = tail.lastRange(of: Data("%%EOF".utf8)) else { return false }
        return tail[marker.upperBound...].allSatisfy { [0x20, 0x09, 0x0A, 0x0D].contains($0) }
    }

    /// Waits until the file stops growing and ends with %%EOF. macOS file locks are advisory, so
    /// "can I open it?" succeeds mid-write; this is how to tell a scanner is done. False if
    /// `maxWait` passes first or the file disappears.
    public static func waitUntilComplete(_ url: URL, pollInterval: Duration = .seconds(1),
                                         maxWait: Duration = .seconds(300)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + maxWait
        var lastSize: UInt64 = .max
        while clock.now < deadline {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value else { return false }
            if size > 0, size == lastSize, endsWithEOFMarker(url) { return true }
            lastSize = size
            do { try await Task.sleep(for: pollInterval) } catch { return false }
        }
        return false
    }

    struct Failure: LocalizedError, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
        var errorDescription: String? { description }
    }
}
