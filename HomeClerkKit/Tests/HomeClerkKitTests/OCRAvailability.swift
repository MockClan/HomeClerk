import CoreGraphics
import CoreText
import Foundation
import Testing
import Vision

/// Whether Apple Vision can read text on this machine. On GitHub's macOS runners — virtual
/// machines without the Neural Engine — its accurate recognizer fails, so tests that need real
/// OCR skip there, with Vision's error in the log. Anywhere that isn't CI (your Mac included) they
/// always run, so OCR that breaks after a macOS update still fails them.
enum OCRAvailability {
    /// Running under CI (GitHub Actions sets CI=true).
    static var onCI: Bool { ProcessInfo.processInfo.environment["CI"] == "true" }

    /// Checked once per test run.
    private static let check = Task<Bool, Never> {
        guard onCI else { return true }
        do {
            let text = try recognize(render("ACME POWER 88.12"))
            if text.uppercased().contains("ACME") { return true }
            print("⚠️ OCR tests skipped: Vision read \(text.isEmpty ? "nothing" : "\"\(text)\"") from a line of rendered text")
        } catch {
            print("⚠️ OCR tests skipped: Vision text recognition failed on this machine: \(error)")
        }
        return false
    }

    static func usable() async -> Bool { await check.value }

    /// A line of black text on white, at roughly OCR resolution.
    private static func render(_ text: String) -> CGImage {
        let width = 1200, height = 200
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 72, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font]))
        context.textPosition = CGPoint(x: 40, y: 70)
        CTLineDraw(line, context)
        return context.makeImage()!
    }

    private static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}

extension Trait where Self == ConditionTrait {
    /// For tests that need Vision to actually read text (see `OCRAvailability`).
    static var requiresOCR: Self {
        .enabled("Needs Vision text recognition, which GitHub's virtual Macs can't run") { await OCRAvailability.usable() }
    }
}
