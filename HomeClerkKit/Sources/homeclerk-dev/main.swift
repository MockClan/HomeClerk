// homeclerk-dev — developer and maintenance commands for the Swift version of HomeClerk.
//
//   homeclerk-dev eval [--analyzer claude|ollama|apple] [--model M] [--only id …]
//                     [--label L] [--dir ~/HomeClerk-TestData] [--parallel 4] [--allow-spend]
//   homeclerk-dev backfill plan [--analyzer claude|ollama|apple] [--match words …] [--limit N] [--allow-spend]
//   homeclerk-dev backfill apply <plan.json>
//   homeclerk-dev backfill undo <backfill-undo-….json>
//   homeclerk-dev rebuild-duplicate-index
//
// eval scores an analyzer against the private test set and writes a report under runs/. backfill
// re-analyzes what's already in Organized and proposes moves and renames for review before applying
// them. Commands that bill the Claude API need --allow-spend; commands that move files or rewrite
// the duplicate index won't run while HomeClerk.app is open.

import AppKit
import CryptoKit
import HomeClerkKit
import Foundation

struct Failure: Error, CustomStringConvertible { let description: String }

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// --name value pairs, flags, and --only's list of ids.
struct Options {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var only: [String] = []

    init(_ args: ArraySlice<String>) {
        var args = Array(args)
        while !args.isEmpty {
            let arg = args.removeFirst()
            guard arg.hasPrefix("--") else { fail("Unexpected argument: \(arg)") }
            let name = String(arg.dropFirst(2))
            switch name {
            case "allow-spend": flags.insert(name)
            case "only", "match":
                while let next = args.first, !next.hasPrefix("--") { only.append(args.removeFirst()) }
            default:
                guard !args.isEmpty else { fail("--\(name) needs a value") }
                values[name] = args.removeFirst()
            }
        }
    }
}

/// taxonomy.json: HOMECLERK_TAXONOMY, the repository's copy, or one next to this executable.
func findTaxonomy() -> URL? {
    let env = ProcessInfo.processInfo.environment["HOMECLERK_TAXONOMY"].map { URL(fileURLWithPath: $0) }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    return [env, cwd.appendingPathComponent("Resources/taxonomy.json"),
            cwd.appendingPathComponent("../Resources/taxonomy.json"),
            executable.appendingPathComponent(TaxonomyConfig.fileName)]
        .compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
}

func runEval(_ options: Options) async throws -> Int32 {
    let directory = URL(fileURLWithPath: ((options.values["dir"] ?? EvalManifest.defaultDirectory.path) as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(EvalManifest.fileName).path) else {
        throw Failure(description: "No \(EvalManifest.fileName) in \(directory.path)")
    }
    var manifest = try EvalManifest.load(from: directory)
    if !options.only.isEmpty {
        manifest.cases.removeAll { !options.only.contains($0.id) }
        guard !manifest.cases.isEmpty else { throw Failure(description: "--only matched no cases") }
    }

    guard let taxonomyURL = findTaxonomy() else {
        throw Failure(description: "Can't find taxonomy.json — run from the repository or set HOMECLERK_TAXONOMY")
    }
    let taxonomy = try TaxonomyConfig.load(from: taxonomyURL)
    let store = SettingsStore.app
    var settings = store.load()
    if let model = options.values["model"] {
        settings.claudeModel = model
        settings.ollamaModel = model
    }
    let profile = try HouseholdProfile.loadOrEmpty(from: settings.householdProfilePath)

    if let provider = AIProvider(named: options.values["analyzer"] ?? "claude"),
       let reason = settings.readerPolicyProblem(for: provider) { throw Failure(description: reason) }

    let analyzer: any FacetAnalyzer
    switch options.values["analyzer"] ?? "claude" {
    case "claude":
        guard let key = Keychain.readAPIKey() else {
            throw Failure(description: "No Anthropic API key in the Keychain — add one in HomeClerk ▸ Settings")
        }
        analyzer = ClaudeFacetAnalyzer(apiKey: key, model: settings.claudeModel, effort: settings.claudeEffort,
                                       sendPDF: settings.sendPageImages, taxonomy: taxonomy, profile: profile,
                                       ledger: UsageLedger(url: settings.basePath.appendingPathComponent(UsageLedger.fileName)))
    case "ollama":
        analyzer = HomeClerkPipeline.analyzer(.ollama, settings: settings, taxonomy: taxonomy, profile: profile, ledger: nil)
    case "apple":
        analyzer = AppleFacetAnalyzer(model: settings.appleModel, sendImages: settings.sendPageImages,
                                      maxImagePages: settings.maxImagePages, taxonomy: taxonomy, profile: profile)
    case let other:
        throw Failure(description: "--analyzer must be claude, ollama, or apple (got \(other))")
    }

    let description = "\(analyzer.modelName) (facets, page images \(settings.sendPageImages ? "on" : "off"), Swift)"
    print("HomeClerk eval — \(description), \(manifest.cases.count) documents")

    // Paid runs need an explicit opt-in so a stray command can't spend API credit
    if analyzer.isPaid {
        let perDocument: Decimal = settings.claudeModel.contains("opus") ? 0.04 : 0.02
        let estimate = NSDecimalNumber(decimal: perDocument * Decimal(manifest.cases.count)).doubleValue
        guard options.flags.contains("allow-spend") else {
            print(String(format: "This run calls a paid API: about $%.2f (%d documents × ~$%.2f).", estimate,
                         manifest.cases.count, NSDecimalNumber(decimal: perDocument).doubleValue))
            print("Re-run with --allow-spend to proceed, or use --only to test fewer documents.")
            return 2
        }
        print(String(format: "Estimated API cost: about $%.2f", estimate))
    }

    // Local models run one document at a time — parallel requests only queue on the same GPU
    let parallelism = analyzer.isPaid ? Int(options.values["parallel"] ?? "4") ?? 4 : 1
    let total = manifest.cases.count
    let runner = EvalRunner(taxonomy: taxonomy)
    let scores = await runner.run(manifest, analyzer: analyzer, parallelism: parallelism) { done in
        FileHandle.standardError.write(Data("\rEvaluated \(done)/\(total)".utf8))
    }
    FileHandle.standardError.write(Data("\n".utf8))

    print("")
    print("Field".padding(toLength: 15, withPad: " ", startingAt: 0) + "Correct".leftPadded(9) + "Accuracy".leftPadded(10))
    for t in EvalRunner.totals(scores) {
        print(t.field.padding(toLength: 15, withPad: " ", startingAt: 0) + "\(t.passed)/\(t.scored)".leftPadded(9)
              + percent(t.passed, t.scored).leftPadded(10))
    }
    let passed = scores.map(\.passed).reduce(0, +), scored = scores.map(\.scored).reduce(0, +)
    print("All fields".padding(toLength: 15, withPad: " ", startingAt: 0) + "\(passed)/\(scored)".leftPadded(9)
          + percent(passed, scored).leftPadded(10))
    let errors = scores.filter { $0.error != nil }.count
    if errors > 0 { print("\(errors) case(s) errored — see report") }

    let report = try runner.writeReport(scores, manifest: manifest, label: options.values["label"] ?? "run",
                                        description: description)
    print("Report: \(report.path)")
    return 0
}

func percent(_ passed: Int, _ scored: Int) -> String {
    scored == 0 ? "—" : "\(Int((Double(passed) / Double(scored) * 100).rounded()))%"
}

extension String {
    func leftPadded(_ width: Int) -> String { String(repeating: " ", count: max(0, width - count)) + self }
}

// MARK: - Backfill and maintenance

struct Environment {
    let taxonomy: TaxonomyConfig
    let settings: HomeClerkSettings
    let profile: HouseholdProfile

    static func load() throws -> Environment {
        guard let taxonomyURL = findTaxonomy() else {
            throw Failure(description: "Can't find taxonomy.json — run from the repository or set HOMECLERK_TAXONOMY")
        }
        let store = SettingsStore.app
        let settings = store.load()
        // Filing works with your own rules (taxonomy.json in the HomeClerk folder) when you have them
        let taxonomy = try TaxonomyConfig.loadEffective(custom: settings.basePath.appendingPathComponent(TaxonomyConfig.fileName),
                                                        builtIn: taxonomyURL)
        if let problem = taxonomy.problem { print("Your taxonomy.json isn't usable, so the built-in rules are: \(problem)") }
        return Environment(taxonomy: taxonomy.config, settings: settings,
                           profile: try HouseholdProfile.loadOrEmpty(from: settings.householdProfilePath))
    }

    var index: DocumentIndex { DocumentIndex(url: settings.basePath.appendingPathComponent(DocumentIndex.fileName)) }
    var duplicates: DuplicateDetector {
        DuplicateDetector(duplicatesFolder: settings.duplicatesFolder, hammingThreshold: settings.duplicateHammingThreshold)
    }
}

/// Moving files or rewriting the duplicate index while the app is filing could lose its changes.
func requireAppClosed() throws {
    if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.mockclan.homeclerk").isEmpty {
        throw Failure(description: "Quit HomeClerk.app first — it's using the same folders and indexes.")
    }
}

func runBackfillPlan(_ options: Options) async throws -> Int32 {
    let env = try Environment.load()
    let name = options.values["analyzer"] ?? "claude"
    guard let provider = AIProvider(named: name) else {
        throw Failure(description: "--analyzer must be claude, ollama, or apple (got \(name))")
    }
    let analyzer = HomeClerkPipeline.analyzer(provider, settings: env.settings, taxonomy: env.taxonomy, profile: env.profile,
                                             ledger: UsageLedger(url: env.settings.basePath.appendingPathComponent(UsageLedger.fileName)))
    let planner = BackfillPlanner(settings: env.settings, taxonomy: env.taxonomy, profile: env.profile)
    let files = planner.selectFiles(limit: Int(options.values["limit"] ?? "0") ?? 0, match: options.only)
    print("HomeClerk backfill plan — \(analyzer.modelName), \(files.count) documents in \(env.settings.outboxFolder.path)")

    if analyzer.isPaid {
        // Only files without a cached result for this model cost anything
        let model = analyzer.modelName.replacing(/[^A-Za-z0-9.\-]+/, with: "_")
        let cache = env.settings.basePath.appendingPathComponent(".homeclerk-cache/analysis/\(model)")
        let uncached = files.filter { file in
            guard let data = try? Data(contentsOf: env.settings.outboxFolder.appendingPathComponent(file)) else { return false }
            return !FileManager.default.fileExists(atPath: cache.appendingPathComponent("\(sha256(data)).json").path)
        }.count
        let estimate = Double(uncached) * (env.settings.claudeModel.contains("opus") ? 0.04 : 0.02)
        guard options.flags.contains("allow-spend") else {
            print(String(format: "This calls a paid API for %d uncached documents: about $%.2f.", uncached, estimate))
            print("Re-run with --allow-spend to proceed, or --limit N / --match words to try a few first.")
            return 2
        }
        print(String(format: "%d uncached documents — estimated API cost about $%.2f", uncached, estimate))
    }

    let total = files.count
    let plan = await planner.plan(files, analyzer: analyzer, parallelism: analyzer.isPaid ? 4 : 1) { done in
        FileHandle.standardError.write(Data("\rPlanned \(done)/\(total)".utf8))
    }
    FileHandle.standardError.write(Data("\n".utf8))

    let folder = env.settings.basePath.appendingPathComponent("backfill")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let stamp = Date().formatted(Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
        timeZone: .current, calendar: .current))
    let planURL = folder.appendingPathComponent("plan-\(stamp).json")
    try plan.save(to: planURL)
    let summary = planURL.deletingPathExtension().appendingPathExtension("md")
    try plan.markdown().write(to: summary, atomically: true, encoding: .utf8)

    for action in Set(plan.entries.map(\.action)).sorted() {
        let group = plan.entries.filter { $0.action == action }
        print("\(action.rawValue.capitalized.padding(toLength: 8, withPad: " ", startingAt: 0)) \(group.count) (\(group.filter(\.apply).count) will be applied)")
    }
    print("Review: \(summary.path)")
    print("Then:   homeclerk-dev backfill apply \"\(planURL.path)\"")
    return 0
}

func runBackfillApply(_ path: String) async throws -> Int32 {
    try requireAppClosed()
    let env = try Environment.load()
    let planURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let plan = try BackfillPlan.load(from: planURL)
    print("Applying backfill — \(plan.entries.filter { $0.apply && $0.action != .skip }.count) documents")
    let result = try await BackfillApplier(finisher: Finisher(env.settings), index: env.index, duplicates: env.duplicates)
        .apply(plan, undoFolder: planURL.deletingLastPathComponent())
    print("Moved \(result.moved), renamed \(result.renamed); finished \(result.finished) (text layer, tags, index).")
    for problem in result.problems { print("  \(problem)") }
    print("Undo with: homeclerk-dev backfill undo \"\(result.undoLog.path)\"")
    return 0
}

func runBackfillUndo(_ path: String) throws -> Int32 {
    try requireAppClosed()
    let env = try Environment.load()
    let (restored, problems) = try BackfillApplier.undo(URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
                                                        organized: env.settings.outboxFolder)
    print("Restored \(restored) documents (files and metadata for snapshot logs).")
    for problem in problems { print("  \(problem)") }
    return problems.isEmpty ? 0 : 1
}

func runRebuildDuplicateIndex() throws -> Int32 {
    try requireAppClosed()
    let env = try Environment.load()
    let (documents, withText) = try BackfillApplier.rebuildDuplicateIndex(env.index, duplicates: env.duplicates,
                                                                          organized: env.settings.outboxFolder)
    print("Duplicate index rebuilt: \(documents) documents (\(withText) with enough text for rescan detection).")
    return 0
}

func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

let usage = """
    Usage: homeclerk-dev eval [--analyzer claude|ollama|apple] [--model M] [--only id …] [--label L]
                             [--dir ~/HomeClerk-TestData] [--parallel 4] [--allow-spend]
           homeclerk-dev backfill plan [--analyzer claude|ollama|apple] [--match words …] [--limit N] [--allow-spend]
           homeclerk-dev backfill apply <plan.json>
           homeclerk-dev backfill undo <backfill-undo-….json>
           homeclerk-dev rebuild-duplicate-index
    """

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch (arguments.first, arguments.dropFirst().first) {
    case ("eval", _):
        exit(try await runEval(Options(arguments.dropFirst())))
    case ("backfill", "plan"):
        exit(try await runBackfillPlan(Options(arguments.dropFirst(2))))
    case ("backfill", "apply") where arguments.count == 3:
        exit(try await runBackfillApply(arguments[2]))
    case ("backfill", "undo") where arguments.count == 3:
        exit(try runBackfillUndo(arguments[2]))
    case ("rebuild-duplicate-index", _):
        exit(try runRebuildDuplicateIndex())
    default:
        fail(usage)
    }
} catch {
    fail("\(error)")
}
