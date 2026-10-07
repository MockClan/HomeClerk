import Foundation

/// Recheck the app's persisted policy at dispatch, including after OCR or a retry delay, so an
/// older pipeline cannot send to a now-blocked reader while settings are restarting.
struct LiveReaderPolicyAnalyzer: FacetAnalyzer {
    let modelName: String
    let isPaid: Bool
    let policy: @Sendable () -> Bool
    let build: @Sendable (Bool) -> any FacetAnalyzer

    func analyze(ocrText: String, pageCount: Int, pdf: URL) async -> FacetAnalysis {
        guard !Task.isCancelled else { return .failed("Cancelled") }
        return await build(policy()).analyze(ocrText: ocrText, pageCount: pageCount, pdf: pdf)
    }
}
