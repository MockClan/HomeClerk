import Foundation

/// Runs every test case through OCR → analyze without touching the real HomeClerk folders,
/// scores the results, and writes a report under runs/. OCR text is cached by file hash in
/// cache/ocr, so repeat runs only pay for the AI calls and
/// every analyzer is scored on the same text.
public struct EvalRunner: Sendable {
    public let router: FilingRouter
    public let names: FilenameBuilder

    public init(taxonomy: TaxonomyConfig) {
        router = FilingRouter(taxonomy)
        names = FilenameBuilder(taxonomy)
    }

    public struct Totals: Sendable {
        public var field: String
        public var passed: Int
        public var scored: Int
    }

    /// Scores every case, `parallelism` at a time, calling `progress` after each one.
    public func run(_ manifest: EvalManifest, analyzer: any FacetAnalyzer, parallelism: Int,
                    progress: @escaping @Sendable (Int) -> Void = { _ in }) async -> [CaseScore] {
        let resilient = ResilientFacetAnalyzer(primary: analyzer, fallback: nil)
        var scores = [CaseScore?](repeating: nil, count: manifest.cases.count)
        await withTaskGroup(of: (Int, CaseScore).self) { group in
            var next = 0, done = 0
            func startNext() {
                guard next < manifest.cases.count else { return }
                let index = next
                next += 1
                group.addTask { (index, await runCase(manifest, manifest.cases[index], resilient)) }
            }
            for _ in 0..<max(1, parallelism) { startNext() }
            for await (index, score) in group {
                scores[index] = score
                done += 1
                progress(done)
                startNext()
            }
        }
        return scores.compactMap { $0 }
    }

    private func runCase(_ manifest: EvalManifest, _ c: EvalCase, _ analyzer: ResilientFacetAnalyzer) async -> CaseScore {
        do {
            let (text, pages) = try await ocr(manifest, c)
            let analysis = await analyzer.analyze(ocrText: text, pageCount: pages, pdf: manifest.scanURL(c))
            if let error = analysis.error {
                return CaseScore(evalCase: c, observed: ObservedFacts(), fields: [], error: error)
            }
            // Test cases are single documents, so score the first and record any spurious split
            let first = analysis.documents[0]
            let observed = ObservedFacts(facets: first.facets, router: router, names: names, confidence: first.confidence,
                                         splitCount: analysis.documents.count > 1 ? analysis.documents.count : 0,
                                         reasoning: analysis.summary)
            return EvalScorer.score(c, observed, router: router)
        } catch {
            return CaseScore(evalCase: c, observed: ObservedFacts(), fields: [], error: "\(error)")
        }
    }

    struct OCRFailure: Error, CustomStringConvertible {
        var description: String { "OCR returned no text" }
    }

    /// The cached OCR text, or Vision's, cached for next time.
    func ocr(_ manifest: EvalManifest, _ c: EvalCase) async throws -> (String, Int) {
        let cache = manifest.ocrCacheURL(c)
        if let text = try? String(contentsOf: cache, encoding: .utf8), let json = try? JSONValue(parsing: text),
           let ocrText = json["Text"]?.stringValue, let pages = json["Pages"]?.doubleValue.flatMap(Int.init(checking:)) {
            return (ocrText, pages)
        }
        let (text, pages) = try await TextRecognizer.text(ofPDF: manifest.scanURL(c))
        // A blank result is an OCR failure, not a blank scan — every test document has text.
        // Failing here keeps it out of the cache.
        guard !text.allSatisfy(\.isWhitespace) else { throw OCRFailure() }
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONValue.object([("Pages", .number(Double(pages))), ("Text", .string(text))]).serialized
            .write(to: cache, atomically: true, encoding: .utf8)
        return (text, pages)
    }

    // MARK: - Reporting

    public static func totals(_ scores: [CaseScore]) -> [Totals] {
        EvalScorer.fieldOrder.compactMap { field in
            let produced = scores.flatMap(\.fields).filter { $0.field == field && ($0.status == .pass || $0.status == .fail) }
            return produced.isEmpty ? nil
                : Totals(field: field, passed: produced.filter { $0.status == .pass }.count, scored: produced.count)
        }
    }

    static func percent(_ passed: Int, _ scored: Int) -> String {
        scored == 0 ? "—" : "\(Int((Double(passed) / Double(scored) * 100).rounded()))%"
    }

    /// Writes results.json and report.md to runs/<timestamp>-<label>; returns the report's URL.
    public func writeReport(_ scores: [CaseScore], manifest: EvalManifest, label: String, description: String) throws -> URL {
        let stamp = Date().formatted(Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
            timeZone: .current, calendar: .current))
        let runDir = manifest.directory.appendingPathComponent("runs/\(stamp)-\(label)")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)

        let results: JSONValue = .object([
            ("label", .string(label)),
            ("description", .string(description)),
            ("ranAt", .string(Date().formatted(.iso8601))),
            ("cases", .array(scores.map { s in
                .object([
                    ("id", .string(s.evalCase.id)),
                    ("error", s.error.map(JSONValue.string) ?? .null),
                    ("filename", .string(s.observed.filename)),
                    ("confidence", .number(s.observed.confidence)),
                    ("summary", .string(s.observed.reasoning)),
                    ("fields", .array(s.fields.map { f in
                        .object([("field", .string(f.field)), ("expected", .string(f.expected)),
                                 ("actual", .string(f.actual)), ("status", .string(f.status.rawValue))])
                    }))
                ])
            }))
        ])
        try results.serialized.write(to: runDir.appendingPathComponent("results.json"), atomically: true, encoding: .utf8)

        let report = runDir.appendingPathComponent("report.md")
        try buildReport(scores, manifest: manifest, label: label, description: description)
            .write(to: report, atomically: true, encoding: .utf8)
        return report
    }

    func buildReport(_ scores: [CaseScore], manifest: EvalManifest, label: String, description: String) -> String {
        var out = ""
        func line(_ s: String = "") { out += s + "\n" }
        let passed = scores.map(\.passed).reduce(0, +), scored = scores.map(\.scored).reduce(0, +)
        let when = Date().formatted(Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: .current, calendar: .current))

        line("# HomeClerk accuracy — \(label)")
        line()
        line("\(description) · \(when) · \(scores.count) documents")
        line()
        line("**Overall: \(passed)/\(scored) fields correct (\(Self.percent(passed, scored)))**")
        line()
        line("| Field | Correct | Accuracy |")
        line("|---|---:|---:|")
        for t in Self.totals(scores) { line("| \(t.field) | \(t.passed)/\(t.scored) | \(Self.percent(t.passed, t.scored)) |") }

        var notProduced: [String] = []
        for f in scores.flatMap(\.fields) where f.status == .notProduced && !notProduced.contains(f.field) {
            notProduced.append(f.field)
        }
        if !notProduced.isEmpty { line("\nNot produced by this analyzer (not scored): \(notProduced.joined(separator: ", "))") }

        line("\n## Cases\n")
        line("| Case | Score | Folder | Misses |")
        line("|---|---:|---|---|")
        for s in scores {
            let folder = s.fields.first { $0.field == "folder" }
            let folderCell = folder.map { $0.status == .pass ? "✓" : "✗ \($0.actual)" } ?? "—"
            let misses = s.error ?? s.fields.filter { $0.status == .fail && $0.field != "folder" }.map(\.field)
                .joined(separator: ", ")
            line("| \(s.evalCase.id) | \(s.passed)/\(s.scored) | \(cell(folderCell)) | \(cell(misses)) |")
        }

        line("\n## Misses\n")
        for s in scores where s.error != nil || s.fields.contains(where: { $0.status == .fail }) {
            line("### \(s.evalCase.id)")
            line("_\(s.evalCase.why)_  ")
            let split = s.observed.splitCount > 0 ? " · split into \(s.observed.splitCount)" : ""
            line("Filename: `\(s.observed.filename)` · confidence \(Int((s.observed.confidence * 100).rounded()))%\(split)")
            line()
            if let error = s.error { line("**Error:** \(error)\n") }
            line("| Field | Expected | Got |")
            line("|---|---|---|")
            for f in s.fields where f.status == .fail { line("| \(f.field) | \(cell(f.expected)) | \(cell(f.actual)) |") }
            if !s.observed.reasoning.isEmpty { line("\n> \(s.observed.reasoning.replacingOccurrences(of: "\n", with: " "))") }
            line()
        }

        let toVerify = scores.filter { $0.fields.contains { $0.status == .verify } }
        if !toVerify.isEmpty {
            line("## Needs your answer\n")
            line("Confirm or correct each value, then put it in `expected` in expected.json and remove it from `verify`.\n")
            for s in toVerify {
                line("### \(s.evalCase.id)")
                line("_\(s.evalCase.why)_\n")
                for f in s.fields where f.status == .verify { line("- **\(f.field)**: model says `\(f.actual)`") }
                line("\n<details><summary>OCR text</summary>\n\n```\n\(excerpt(manifest, s.evalCase))\n```\n</details>\n")
            }
        }
        return out
    }

    private func excerpt(_ manifest: EvalManifest, _ c: EvalCase) -> String {
        guard let text = try? String(contentsOf: manifest.ocrCacheURL(c), encoding: .utf8),
              let ocr = (try? JSONValue(parsing: text))?["Text"]?.stringValue else { return "(no OCR cached)" }
        let lines = ocr.split(separator: "\n", omittingEmptySubsequences: false)
        let maxLines = 60
        return lines.prefix(maxLines).joined(separator: "\n") + (lines.count > maxLines ? "\n… (\(lines.count - maxLines) more lines)" : "")
    }

    private func cell(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
