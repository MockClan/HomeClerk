import CryptoKit
import Foundation

/// Re-analyzes documents already in Organized and proposes where each belongs under the current
/// taxonomy and naming rules. Changes nothing except its caches: OCR text and model results are
/// cached by file hash, so re-planning is free.
public struct BackfillPlanner: Sendable {
    let settings: HomeClerkSettings
    let router: FilingRouter
    let names: FilenameBuilder
    let profile: HouseholdProfile
    let cacheFolder: URL

    public init(settings: HomeClerkSettings, taxonomy: TaxonomyConfig, profile: HouseholdProfile) {
        self.settings = settings
        router = FilingRouter(taxonomy)
        names = FilenameBuilder(taxonomy)
        self.profile = profile
        cacheFolder = settings.basePath.appendingPathComponent(".homeclerk-cache")
    }

    /// The documents to plan, in a stable order: those whose path (relative to Organized) contains
    /// every word in `match` (ignoring case, _ as a space), then the first `limit` when above zero.
    public func selectFiles(limit: Int = 0, match: [String] = []) -> [String] {
        let words = match.map(Self.normalize)
        let root = settings.outboxFolder
        let all = (FileManager.default.subpaths(atPath: root.path) ?? [])
            .filter { $0.lowercased().hasSuffix(".pdf") && !$0.split(separator: "/").contains { $0.hasPrefix(".") } }
            .filter { FileOrganizer.isInside(root.appendingPathComponent($0), root) }
            .filter { path in words.allSatisfy { Self.normalize(path).contains($0) } }
            .sorted()
        return limit > 0 ? Array(all.prefix(limit)) : all
    }

    /// Plans the given files (relative to Organized), `parallelism` at a time.
    public func plan(_ files: [String], analyzer: any FacetAnalyzer, parallelism: Int,
                     progress: @escaping @Sendable (Int) -> Void = { _ in }) async -> BackfillPlan {
        let machineFiled = machineFiledPaths()
        var entries = [BackfillEntry?](repeating: nil, count: files.count)
        await withTaskGroup(of: (Int, BackfillEntry).self) { group in
            var next = 0, done = 0
            func startNext() {
                guard next < files.count else { return }
                let i = next
                next += 1
                group.addTask { (i, await planOne(files[i], handCorrected: !machineFiled.contains(files[i]), analyzer: analyzer)) }
            }
            for _ in 0..<max(1, parallelism) { startNext() }
            for await (i, entry) in group {
                entries[i] = entry
                done += 1
                progress(done)
                startNext()
            }
        }
        return BackfillPlan(createdAt: Date(), organizedFolder: settings.outboxFolder.path, model: analyzer.modelName,
                            entries: entries.compactMap { $0 })
    }

    func planOne(_ relative: String, handCorrected: Bool, analyzer: any FacetAnalyzer) async -> BackfillEntry {
        let file = settings.outboxFolder.appendingPathComponent(relative)
        guard FileOrganizer.isInside(settings.outboxFolder, settings.basePath),
              FileOrganizer.isInside(file, settings.outboxFolder) else {
            var entry = BackfillEntry(path: relative, sha256: "", handCorrected: handCorrected)
            entry.reason = "Outside Organized or contains a symbolic link — skipped"
            return entry
        }
        guard let data = try? Data(contentsOf: file) else {
            var entry = BackfillEntry(path: relative, sha256: "", handCorrected: handCorrected)
            entry.reason = "Analysis failed: can't read the file"
            return entry
        }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var entry = BackfillEntry(path: relative, sha256: sha, handCorrected: handCorrected)

        let analysis: FacetAnalysis
        do {
            let (text, pages) = try await ocr(file, sha: sha)
            analysis = await analyze(analyzer, text: text, pages: pages, file: file, sha: sha)
        } catch {
            entry.reason = "Analysis failed: \(error)"
            return entry
        }
        if let error = analysis.error {
            entry.reason = error
            entry.model = analyzer.modelName
            return entry
        }

        // Cached analyses may predate edits to household.json, so canonicalize against the current profile
        var document = analysis.documents[0]
        document.facets = profile.canonicalize(document.facets)
        entry.model = analyzer.modelName
        entry.summary = analysis.summary
        entry.confidence = document.confidence
        entry.facets = document.facets

        if analysis.documents.count > 1 {
            entry.reason = "Model sees \(analysis.documents.count) documents in this file; backfill doesn't split"
            return entry
        }
        if document.confidence < settings.minConfidenceThreshold {
            entry.reason = "Low confidence (\(DocumentProcessor.percent(document.confidence)))"
            return entry
        }

        let folder = router.folder(for: document.facets)
        let name = names.build(document.facets)
        let currentFolder = (relative as NSString).deletingLastPathComponent
        let currentName = (relative as NSString).lastPathComponent
        entry.action = folder != currentFolder ? .move : !Self.sameName(name, currentName) ? .rename : .keep
        entry.reason = switch entry.action {
        case .move: "Now files under \(folder)"
        case .rename: "Name follows current naming rules"
        default: "Already where it belongs"
        }
        // A human's placement wins by default: show the proposal, don't apply it
        entry.apply = !(handCorrected && (entry.action == .move || entry.action == .rename))
        if !entry.apply { entry.reason += " — you filed this by hand, so it's left alone unless you set apply to true" }
        entry.proposedFolder = folder
        entry.proposedName = name
        return entry
    }

    /// Ignores the _2, _3 suffixes added to avoid name collisions.
    static func sameName(_ proposed: String, _ current: String) -> Bool {
        func strip(_ name: String) -> String {
            let ext = (name as NSString).pathExtension
            let stem = ((name as NSString).deletingPathExtension).replacing(/_\d+$/, with: "")
            return ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        return strip(proposed) == strip(current)
    }

    static func normalize(_ s: String) -> String { s.replacingOccurrences(of: "_", with: " ").lowercased() }

    /// Organized paths HomeClerk itself filed — from index.jsonl, and the logs older versions wrote.
    /// Anything else was moved or renamed by hand afterwards: a correction backfill shouldn't override.
    /// Only the pipeline's own filings count: a "backfill:" entry is also written for documents a person
    /// placed that the model agreed with, and a "review:" entry is a person's decision.
    func machineFiledPaths() -> Set<String> {
        var paths = Set<String>()
        let base = settings.outboxFolder.standardizedFileURL.path + "/"
        for entry in DocumentIndex(url: settings.basePath.appendingPathComponent(DocumentIndex.fileName)).load()
        where entry.path.hasPrefix(base) && !entry.source.hasPrefix("backfill:") && !entry.source.hasPrefix("review:") {
            paths.insert(String(entry.path.dropFirst(base.count)))
        }
        let logs = (try? FileManager.default.contentsOfDirectory(at: settings.basePath, includingPropertiesForKeys: nil)) ?? []
        for log in logs where (log.lastPathComponent.hasPrefix("homeclerk-") || log.lastPathComponent.hasPrefix(Legacy.logPrefix)) && log.pathExtension == "log" {
            guard let text = try? String(contentsOf: log, encoding: .utf8) else { continue }
            for match in text.matches(of: /\/Organized\/(?<path>[^\r\n]+?\.pdf)/) { paths.insert(String(match.output.path)) }
        }
        let index = DocumentIndex(url: settings.basePath.appendingPathComponent(DocumentIndex.fileName))
        let latest = Dictionary(index.load().map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
        for entry in latest.values where entry.removed {
            if let relative = FileOrganizer.relativePath(URL(fileURLWithPath: entry.path), in: settings.outboxFolder) { paths.remove(relative) }
        }
        return paths
    }

    // MARK: - Caches

    func ocr(_ file: URL, sha: String) async throws -> (String, Int) {
        let cache = cacheFolder.appendingPathComponent("ocr/\(sha).json")
        if let text = try? String(contentsOf: cache, encoding: .utf8), let json = try? JSONValue(parsing: text),
           let ocr = json["Text"]?.stringValue, let pages = json["Pages"]?.doubleValue.flatMap(Int.init(checking:)) {
            return (ocr, pages)
        }
        let (text, pages) = try await TextRecognizer.text(ofPDF: file)
        // Blank OCR is usually a Vision failure; don't cache it so a re-run retries
        if !text.allSatisfy(\.isWhitespace) {
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONValue.object([("Pages", .number(Double(pages))), ("Text", .string(text))]).serialized
                .write(to: cache, atomically: true, encoding: .utf8)
        }
        return (text, pages)
    }

    /// Successful analyses are cached per model, so a paid model is never billed twice for a file.
    func analyze(_ analyzer: any FacetAnalyzer, text: String, pages: Int, file: URL, sha: String) async -> FacetAnalysis {
        let model = analyzer.modelName.replacing(/[^A-Za-z0-9.\-]+/, with: "_")
        let cache = cacheFolder.appendingPathComponent("analysis/\(model)/\(sha).json")
        if let cached = Self.loadCachedAnalysis(cache) {
            var analysis = cached
            analysis.model = analyzer.modelName
            return analysis
        }
        let analysis = await analyzer.analyze(ocrText: text, pageCount: pages, pdf: file)
        if analysis.error == nil {
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let json = try? ReviewProposal.json(analysis) {
                // The cache keeps only the documents and the summary
                let slim: JSONValue = .object([("Documents", json["Documents"] ?? .array([])), ("Summary", json["Summary"] ?? .string(""))])
                try? slim.serialized.write(to: cache, atomically: true, encoding: .utf8)
            }
        }
        return analysis
    }

    static func loadCachedAnalysis(_ url: URL) -> FacetAnalysis? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Same shape as a review proposal's documents and summary
        return ReviewProposal.load(from: url)
    }
}
