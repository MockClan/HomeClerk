import Foundation
import Testing
@testable import HomeClerkKit

@Suite struct TaxonomyEditingTests {
    let temp = TempFolder()
    var builtIn: URL { TestData.repository.appendingPathComponent("Resources/taxonomy.json") }

    @Test func writtenRulesReadBackTheSame() throws {
        let url = temp.url.appendingPathComponent("taxonomy.json")
        try TestData.taxonomy.save(to: url)
        let reread = try TaxonomyConfig.load(from: url)
        #expect(reread.json == TestData.taxonomy.json)
        #expect(reread.rules.count == TestData.taxonomy.rules.count && reread.retention == TestData.taxonomy.retention)
    }

    @Test func yourCopyIsUsedWhenValidAndExplainedWhenNot() throws {
        let custom = temp.url.appendingPathComponent("taxonomy.json")
        #expect(try !TaxonomyConfig.loadEffective(custom: custom, builtIn: builtIn).usingCustom)

        var mine = TestData.taxonomy
        mine.rules.insert(FilingRule(folder: "Kid Stuff", condition: FacetCondition(tagsAny: ["school"])), at: 0)
        try mine.save(to: custom)
        let loaded = try TaxonomyConfig.loadEffective(custom: custom, builtIn: builtIn)
        #expect(loaded.usingCustom && loaded.config.rules.first?.folder == "Kid Stuff" && loaded.problem == nil)

        try "{ \"areas\": [] }".write(to: custom, atomically: true, encoding: .utf8)
        let broken = try TaxonomyConfig.loadEffective(custom: custom, builtIn: builtIn)
        #expect(!broken.usingCustom && broken.problem?.contains("areas") == true)
    }

    @Test func invalidRulesAreNeverSaved() {
        var bad = TestData.taxonomy
        bad.rules.append(FilingRule(folder: "Nowhere", condition: FacetCondition(area: "Not_An_Area")))
        #expect(throws: TaxonomyConfig.InvalidError.self) { try bad.save(to: temp.url.appendingPathComponent("t.json")) }
    }

    @Test func refileMovesListDocumentsTheRulesWouldPlaceElsewhere() throws {
        let settings = HomeClerkSettings(values: ["basepath": .string(temp.url.path)])
        var taxonomy = TestData.taxonomy
        taxonomy.rules.insert(FilingRule(folder: "Kid Stuff", condition: FacetCondition(tagsAny: ["school"])), at: 0)
        let actions = ReviewActions(settings: settings, taxonomy: taxonomy,
                                    finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false,
                                                       remindersList: "x", expirationLeadDays: 30),
                                    index: DocumentIndex(url: temp.url.appendingPathComponent("index.jsonl")),
                                    duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
        func filed(_ folder: String, _ name: String, _ facets: DocumentFacets) throws -> DocumentIndex.Entry {
            let url = settings.outboxFolder.appendingPathComponent("\(folder)/\(name)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try TestPDF.make(url, pages: ["x"])
            return DocumentIndex.Entry(path: url.path, source: "s", pages: [], model: "m", confidence: 1, summary: "", facets: facets)
        }
        let report = DocumentFacets(documentType: "Report", area: "Education", tags: ["school"], vendor: "Example_School",
                                    description: "Report_Card", documentDate: "2026-06-01")
        let moving = try filed("Education", "2026-06-01-Example_School-Report_Card.pdf", report)
        let (folder, name) = actions.destination(report)
        let staying = try filed(folder, name.replacingOccurrences(of: ".pdf", with: "_2.pdf"), report)
        let moves = actions.refileMoves([moving, staying])
        #expect(moves.map(\.entry.path) == [moving.path])
        #expect(moves.first?.fromFolder == "Education" && moves.first?.toFolder == "Kid Stuff")
    }
}
