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

    /// Every page's text, with the page-break marker the prompt expects between pages. Pages are
    /// rendered and recognized one at a time, so a long scan never holds every page image at once.
    /// A page that can't be recognized contributes empty text unless `strict`.
    public static func text(ofPDF pdf: URL, strict: Bool = true) async throws -> (text: String, pages: Int) {
        let document = try PageRenderer.open(pdf)
        var parts: [String] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let image = try PageRenderer.image(of: document, page: index, dpi: PageRenderer.ocrDPI)
            do {
                parts.append(try await text(in: image))
            } catch {
                if strict { throw error }
                parts.append("")
            }
        }
        return (parts.joined(separator: "\n--- Page Break ---\n\n"), document.pageCount)
    }
}
