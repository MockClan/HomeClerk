import Foundation
import Testing
@testable import HomeClerkKit

/// Returns a fixed analysis for each file name and counts calls.
final class ByNameAnalyzer: FacetAnalyzer, @unchecked Sendable {
    let modelName = "Fake model"
    let isPaid = false
    let answers: [String: FacetAnalysis]
    private(set) var calls = 0
    init(_ answers: [String: FacetAnalysis]) { self.answers = answers }
    func analyze(ocrText: String, pageCount: Int, pdf: URL) async -> FacetAnalysis {
        calls += 1
        return answers[pdf.lastPathComponent] ?? .failed("no answer")
    }
}

@Suite struct BackfillTests {
    let temp = TempFolder()
    var settings: HomeClerkSettings { HomeClerkSettings(values: ["basepath": .string(temp.url.path)]) }

    static func bill(vendor: String = "Acme_Power", confidence: Double = 0.95) -> FacetAnalysis {
        FacetAnalysis(documents: [FacetDocument(firstPage: 1, lastPage: 1, facets: DocumentFacets(
            documentType: "Bill", area: "Utilities", vendor: vendor, description: "Electric_Bill", documentDate: "2026-02-03"),
            confidence: confidence)], summary: "A bill.")
    }

    /// Files a PDF under Organized and, unless `byHand`, records it in the index as HomeClerk's own filing.
    func filed(_ relative: String, byHand: Bool = false, source: String = "scan.pdf") throws {
        let url = settings.outboxFolder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TestPDF.make(url, pages: ["ACME POWER electric bill for \(relative)"])
        if !byHand {
            try DocumentIndex(url: settings.basePath.appendingPathComponent(DocumentIndex.fileName))
                .append(DocumentIndex.Entry(path: url.path, source: source, pages: [1, 1], model: "m", confidence: 0.9,
                                            summary: "", facets: DocumentFacets()))
        }
    }

    func planner() -> BackfillPlanner { BackfillPlanner(settings: settings, taxonomy: TestData.taxonomy, profile: .empty) }

    @Test(.requiresOCR) func proposesMovesRenamesAndRespectsHandFiling() async throws {
        try filed("Bills - Utilities/2026-02-03-Acme_Power-Electric_Bill.pdf")       // already right
        try filed("Uncategorized/scan1.pdf")                                         // wrong folder
        try filed("Bills - Utilities/old-name.pdf")                                  // wrong name
        try filed("My Folder/kept-by-me.pdf", byHand: true)                          // moved by hand
        try filed("My Folder/agreed.pdf", source: "backfill:My Folder/agreed.pdf")   // placed by hand, kept by backfill
        try filed("Uncategorized/unsure.pdf")
        let analyzer = ByNameAnalyzer([
            "2026-02-03-Acme_Power-Electric_Bill.pdf": Self.bill(), "scan1.pdf": Self.bill(vendor: "Acme_Gas"),
            "old-name.pdf": Self.bill(vendor: "Acme_Water"), "kept-by-me.pdf": Self.bill(vendor: "Acme_Phone"), "agreed.pdf": Self.bill(vendor: "Acme_Cable"),
            "unsure.pdf": Self.bill(confidence: 0.4)])

        let plan = await planner().plan(planner().selectFiles(), analyzer: analyzer, parallelism: 2)
        let byPath = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.path, $0) })
        #expect(byPath["Bills - Utilities/2026-02-03-Acme_Power-Electric_Bill.pdf"]?.action == .keep)
        #expect(byPath["Uncategorized/scan1.pdf"]?.action == .move)
        #expect(byPath["Uncategorized/scan1.pdf"]?.proposedName == "2026-02-03-Acme_Gas-Electric_Bill.pdf")
        #expect(byPath["Bills - Utilities/old-name.pdf"]?.action == .rename)
        let mine = try #require(byPath["My Folder/kept-by-me.pdf"])
        #expect(mine.action == .move && mine.handCorrected && !mine.apply)
        #expect(byPath["My Folder/agreed.pdf"]?.handCorrected == true)
        #expect(byPath["Uncategorized/unsure.pdf"]?.action == .skip)
        #expect(byPath["Uncategorized/unsure.pdf"]?.reason == "Low confidence (40%)")

        // Re-planning uses the caches: no new model calls
        let calls = analyzer.calls
        _ = await planner().plan(planner().selectFiles(), analyzer: analyzer, parallelism: 1)
        #expect(analyzer.calls == calls)
        #expect(planner().selectFiles(match: ["uncategorized", "scan1"]) == ["Uncategorized/scan1.pdf"])
    }

    @Test(.requiresOCR) func applyThenUndo() async throws {
        try filed("Uncategorized/scan1.pdf")
        let plan = await planner().plan(planner().selectFiles(), analyzer: ByNameAnalyzer(["scan1.pdf": Self.bill()]),
                                        parallelism: 1)
        let planURL = temp.url.appendingPathComponent("plan.json")
        try plan.save(to: planURL)
        #expect(plan.markdown().contains("## Move to a different folder (1)"))

        let applier = BackfillApplier(
            finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "x", expirationLeadDays: 30),
            index: DocumentIndex(url: settings.basePath.appendingPathComponent(DocumentIndex.fileName)),
            duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
        let result = try await applier.apply(try BackfillPlan.load(from: planURL), undoFolder: temp.url.appendingPathComponent("backfill"))
        let moved = settings.outboxFolder.appendingPathComponent("Bills - Utilities/2026-02-03-Acme_Power-Electric_Bill.pdf")
        #expect(result.moved == 1 && result.problems.isEmpty)
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(!FileManager.default.fileExists(atPath: settings.outboxFolder.appendingPathComponent("Uncategorized").path))

        let log = try JSONDecoder().decode([BackfillApplier.UndoMove].self, from: Data(contentsOf: result.undoLog))
        #expect(log.count == 1)
        #expect(log.first?.sha256 == BackfillApplier.sha256(try Data(contentsOf: moved)))
        #expect((try FileManager.default.attributesOfItem(atPath: result.undoLog.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let (restored, problems) = try BackfillApplier.undo(result.undoLog, organized: settings.outboxFolder)
        #expect(restored == 1 && problems.isEmpty)
        #expect(FileManager.default.fileExists(atPath: settings.outboxFolder.appendingPathComponent("Uncategorized/scan1.pdf").path))
    }

    @Test func readsAPlanTheCurrentAppWrote() throws {
        let url = temp.url.appendingPathComponent("plan.json")
        try #"""
            {"created_at": "2026-03-02T08:15:00.1234567-05:00", "organized_folder": "/x/Organized", "model": "Claude m",
             "entries": [{"path": "a/b.pdf", "sha256": "abc", "action": "move", "apply": true, "reason": "Now files under c",
                          "proposed_folder": "c", "proposed_name": "d.pdf", "hand_corrected": false, "confidence": 0.9,
                          "model": "Claude m", "summary": "s", "facets": {"vendor": "Acme"}},
                         {"path": "e.pdf", "sha256": "def", "action": "skip", "apply": false, "reason": "Low confidence (40%)",
                          "proposed_folder": "", "proposed_name": "", "hand_corrected": false, "confidence": 0.4,
                          "model": "", "summary": "", "facets": null}]}
            """#.write(to: url, atomically: true, encoding: .utf8)
        let plan = try BackfillPlan.load(from: url)
        #expect(plan.entries.map(\.action) == [.move, .skip])
        #expect(plan.entries[0].facets?.vendor == "Acme" && plan.entries[1].facets == nil)
    }

    @Test func rebuildsTheDuplicateIndexFromTheLibrary() throws {
        try filed("Bills - Utilities/a.pdf")
        let duplicates = DuplicateDetector(duplicatesFolder: settings.duplicatesFolder)
        let counts = try BackfillApplier.rebuildDuplicateIndex(
            DocumentIndex(url: settings.basePath.appendingPathComponent(DocumentIndex.fileName)), duplicates: duplicates,
            organized: settings.outboxFolder)
        #expect(counts.documents == 1)
        let sha = BackfillApplier.sha256(try Data(contentsOf: settings.outboxFolder.appendingPathComponent("Bills - Utilities/a.pdf")))
        #expect(duplicates.exactDuplicate(sha256: sha) == "Bills - Utilities/a.pdf")
    }
}
