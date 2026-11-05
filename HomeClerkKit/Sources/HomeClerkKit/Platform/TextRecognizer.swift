import CoreGraphics
import Foundation
import Vision

/// OCR with Apple Vision, configured as HomeClerk's OCR helper always has been: accurate
/// recognition, US English, and no language correction — it silently "corrects" exactly the
/// tokens that matter most (drug names, authorization and billing codes, reference numbers).
public enum TextRecognizer {
    public static func text(in image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            // perform runs the request synchronously, so results are ready when it returns
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }

    /// Every page's text, each under a numbered marker ("--- Page 2 of 5 ---") so the reader can
    /// tell where one document ends and the next begins.
    public static func text(ofPDF pdf: URL, strict: Bool = true) async throws -> (text: String, pages: Int) {
        let pages = try await pageTexts(ofPDF: pdf, strict: strict)
        return (joined(pages), pages.count)
    }

    /// Each page's text, in order. Pages are rendered and recognized one at a time, so a long scan
    /// never holds every page image at once. A page that can't be recognized is empty unless `strict`.
    public static func pageTexts(ofPDF pdf: URL, strict: Bool = true) async throws -> [String] {
        let document = try PageRenderer.open(pdf)
        var pages: [String] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let image = try PageRenderer.image(of: document, page: index, dpi: PageRenderer.ocrDPI)
            do {
                pages.append(try await text(in: image))
            } catch {
                if strict { throw error }
                pages.append("")
            }
        }
        return pages
    }

    /// Pages' text under numbered markers, as the reader receives it.
    public static func joined(_ pages: [String]) -> String {
        pages.enumerated().map { "--- Page \($0.offset + 1) of \(pages.count) ---\n\($0.element)" }.joined(separator: "\n\n")
    }

    /// Each page's text back out of `joined` — or out of the unnumbered page breaks that OCR text
    /// saved by earlier versions has.
    public static func pages(of text: String) -> [String] {
        if text.contains("\n--- Page Break ---\n\n") || !text.hasPrefix("--- Page 1 of ") {
            return text.components(separatedBy: "\n--- Page Break ---\n\n")
        }
        return text.components(separatedBy: "\n\n--- Page ").enumerated().map { index, part in
            let body = index == 0 ? String(part.dropFirst("--- Page ".count)) : part
            return body.firstIndex(of: "\n").map { String(body[body.index(after: $0)...]) } ?? ""
        }
    }
}
