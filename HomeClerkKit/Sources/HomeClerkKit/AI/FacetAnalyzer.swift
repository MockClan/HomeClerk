import Foundation

/// A model that describes scanned PDFs as `DocumentFacets`.
public protocol FacetAnalyzer: Sendable {
    /// Human-readable model name for logs and reports, e.g. "Claude claude-sonnet-5-5".
    var modelName: String { get }
    /// True when each call costs money (cloud APIs); false for local models.
    var isPaid: Bool { get }
    /// Never fails for model or network problems — returns `FacetAnalysis.failed` instead.
    func analyze(ocrText: String, pageCount: Int, pdf: URL) async -> FacetAnalysis
}

/// Stops a paid analyzer once the month's spending reaches a limit, so the fallback takes over
/// (or the scan waits in Review) until the next month.
public struct BudgetedAnalyzer: FacetAnalyzer {
    public let wrapped: any FacetAnalyzer
    let ledger: UsageLedger
    /// Dollars per calendar month.
    public let limit: Decimal

    public init(_ wrapped: any FacetAnalyzer, ledger: UsageLedger, limit: Decimal) {
        self.wrapped = wrapped
        self.ledger = ledger
        self.limit = limit
    }

    public var modelName: String { wrapped.modelName }
    public var isPaid: Bool { wrapped.isPaid }

    public func analyze(ocrText: String, pageCount: Int, pdf: URL) async -> FacetAnalysis {
        let spent = ledger.spent()
        guard spent < limit else {
            return .failed("This month's Claude limit of \(FinishingPlan.currency(limit)) is reached "
                           + "(\(FinishingPlan.currency(spent)) spent); it resumes next month")
        }
        return await wrapped.analyze(ocrText: ocrText, pageCount: pageCount, pdf: pdf)
    }
}

/// Retries the primary analyzer on transient failures, then — if it still fails (out of API
/// credit, refusal, outage) — asks the fallback analyzer instead of sending the scan to review.
/// Results carry which model produced them; `onAnalyzing` hears (pdf, model name) each time a
/// model starts on a scan.
public struct ResilientFacetAnalyzer: FacetAnalyzer {
    public static let maxAttempts = 3

    public let primary: any FacetAnalyzer
    public let fallback: (any FacetAnalyzer)?
    let delay: @Sendable (Double) async throws -> Void
    let onAnalyzing: (@Sendable (URL, String) -> Void)?

    public init(primary: any FacetAnalyzer, fallback: (any FacetAnalyzer)?,
                delay: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                onAnalyzing: (@Sendable (URL, String) -> Void)? = nil) {
        self.primary = primary
        self.fallback = fallback
        self.delay = delay
        self.onAnalyzing = onAnalyzing
    }

    public var modelName: String { fallback.map { "\(primary.modelName) → \($0.modelName)" } ?? primary.modelName }
    public var isPaid: Bool { primary.isPaid || fallback?.isPaid == true }

    public func analyze(ocrText: String, pageCount: Int, pdf: URL) async -> FacetAnalysis {
        guard !Task.isCancelled else { return .failed("Cancelled") }
        let result = await withRetries(primary, ocrText, pageCount, pdf)
        guard !Task.isCancelled else { return .failed("Cancelled") }
        guard let primaryError = result.error, let fallback else { return result }

        var rescue = await withRetries(fallback, ocrText, pageCount, pdf)
        if let fallbackError = rescue.error {
            rescue.error = "\(primary.modelName): \(primaryError); fallback \(fallback.modelName): \(fallbackError)"
        } else {
            rescue.usedFallback = true
            rescue.primaryError = primaryError
        }
        return rescue
    }

    private func withRetries(_ analyzer: any FacetAnalyzer, _ ocrText: String, _ pageCount: Int, _ pdf: URL) async
        -> FacetAnalysis {
        onAnalyzing?(pdf, analyzer.modelName)
        for attempt in 1... {
            guard !Task.isCancelled else { return .failed("Cancelled") }
            var analysis = await analyzer.analyze(ocrText: ocrText, pageCount: pageCount, pdf: pdf)
            if analysis.error == nil {
                analysis.model = analyzer.modelName
                return analysis
            }
            guard analysis.isTransientFailure, attempt < Self.maxAttempts else { return analysis }
            let wait = analysis.retryAfterSeconds > 0 ? Double(analysis.retryAfterSeconds) : pow(2, Double(attempt))
            do { try await delay(wait) } catch { return analysis }   // cancelled
        }
        fatalError("unreachable")
    }
}
