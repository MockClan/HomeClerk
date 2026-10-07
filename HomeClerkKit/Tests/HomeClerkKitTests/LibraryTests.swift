import Foundation
import Testing
@testable import HomeClerkKit

@Suite struct DocumentLibraryTests {
    let temp = TempFolder()

    func library(_ entries: DocumentIndex.Entry...) throws -> DocumentLibrary {
        let index = DocumentIndex(url: temp.url.appendingPathComponent("index.jsonl"))
        for entry in entries { try index.append(entry) }
        return DocumentLibrary.load(index)
    }

    func entry(_ path: URL, _ facets: DocumentFacets) -> DocumentIndex.Entry {
        DocumentIndex.Entry(path: path.path, source: "s.pdf", pages: [1, 1], model: "m", confidence: 0.9, summary: "", facets: facets)
    }

    @Test func upcomingListsDueDatesAndExpirationsInWindowSoonestFirst() throws {
        let library = try library(
            entry(try temp.file("bill.pdf"), DocumentFacets(vendor: "Toll_Authority", description: "Toll_Bill", dueDate: "2026-04-24",
                                                            amount: Decimal(string: "31.40"))),
            entry(try temp.file("cert.pdf"), DocumentFacets(vendor: "Sunny_Vet", description: "Rabies_Certificate",
                                                            expiresOn: "2026-04-10", pet: "Biscuit")),
            entry(try temp.file("old.pdf"), DocumentFacets(vendor: "Past", dueDate: "2026-03-04", amount: 5)))
        let items = library.upcoming(from: "2026-04-01", to: "2026-05-31")
        #expect(items.map(\.title) == ["Biscuit: Rabies Certificate (Sunny Vet)", "Toll Authority $31.40 — Toll Bill"])
        #expect(items.map(\.kind) == [.expires, .due])
    }

    @Test func findMatchesAllWordsAcrossFacetsIgnoringUnderscores() throws {
        let rav = try temp.file("rav.pdf")
        let library = try library(
            entry(rav, DocumentFacets(vendor: "Acme_Tire", description: "Oil_Change", documentDate: "2026-02-09", vehicle: "2021_Toyota_RAV4")),
            entry(try temp.file("other.pdf"), DocumentFacets(vendor: "Acme_Tire", description: "Oil_Change", vehicle: "2011_Honda_Civic")))
        #expect(library.find("rav4 oil change").map(\.path) == [rav.path])
        #expect(library.find("acme tire").count == 2)
        #expect(library.find("2026-02").count == 1)
        #expect(library.find("dental").isEmpty)
    }

    @Test func latestEntryWinsAndMissingFilesAreDropped() throws {
        let path = try temp.file("doc.pdf")
        let library = try library(entry(path, DocumentFacets(description: "Old_Name")),
                                  entry(path, DocumentFacets(description: "New_Name")),
                                  entry(temp.url.appendingPathComponent("moved-away.pdf"), DocumentFacets(description: "Gone")))
        #expect(library.documents.map(\.facets.description) == ["New_Name"])
    }
}

@Suite struct ReviewActionsTests {
    let temp = TempFolder()
    var settings: HomeClerkSettings { HomeClerkSettings(values: ["basepath": .string(temp.url.path)]) }

    var actions: ReviewActions {
        ReviewActions(settings: settings, taxonomy: TestData.taxonomy,
                      finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "x",
                                         expirationLeadDays: 30),
                      index: DocumentIndex(url: temp.url.appendingPathComponent("index.jsonl")),
                      duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
    }

    static func proposal() -> FacetAnalysis {
        var analysis = FacetAnalysis(documents: [FacetDocument(firstPage: 1, lastPage: 1, facets: DocumentFacets(
            documentType: "Bill", area: "Vehicle", tags: ["tolls"], vendor: "Toll_Authority", description: "Toll_Bill",
            documentDate: "2026-04-24", amount: Decimal(string: "31.40")), confidence: 0.6)], summary: "A toll bill.")
        analysis.model = "test"
        return analysis
    }

    func reviewScan(_ name: String, proposal: FacetAnalysis? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: settings.reviewFolder, withIntermediateDirectories: true)
        let scan = settings.reviewFolder.appendingPathComponent(name)
        try "%PDF-1.7\n%%EOF".write(to: scan, atomically: true, encoding: .utf8)
        try "Confidence 60% below threshold 70%.\n\nmore".write(to: ReviewProposal.reasonURL(for: scan), atomically: true, encoding: .utf8)
        if let proposal { try ReviewProposal.save(proposal, for: scan) }
        return scan
    }

    @Test func listsPendingScansWithReasonAndProposal() throws {
        _ = try reviewScan("b.pdf")
        _ = try reviewScan("a.pdf", proposal: Self.proposal())
        let pending = actions.pendingScans()
        #expect(pending.map(\.url.lastPathComponent) == ["a.pdf", "b.pdf"])
        #expect(pending[0].reason == "Confidence 60% below threshold 70%.")
        #expect(pending[0].document?.facets.vendor == "Toll_Authority")
        #expect(pending[1].analysis == nil)
    }

    @Test func fileAsProposedUsesTheRulesAndCleansUp() async throws {
        let scan = try reviewScan("scan1.pdf", proposal: Self.proposal())
        let pending = try #require(actions.pendingScans().first)
        let destination = try await actions.fileAsProposed(scan, document: pending.document!, analysis: pending.analysis!).destination
        #expect(destination.path == settings.outboxFolder.appendingPathComponent("Vehicle - Tolls/2026-04-24-Toll_Authority-Toll_Bill-31.40.pdf").path)
        #expect(!FileManager.default.fileExists(atPath: scan.path))
        #expect(!FileManager.default.fileExists(atPath: ReviewProposal.reasonURL(for: scan).path))
        #expect(DocumentIndex(url: temp.url.appendingPathComponent("index.jsonl")).load().first?.source == "review:scan1.pdf")
        #expect(actions.pendingScans().isEmpty)
    }

    @Test func choosingAFolderWithoutAProposalKeepsTheName() async throws {
        let scan = try reviewScan("mystery.pdf")
        let destination = try await actions.fileInFolder(scan, folder: "Legal", document: nil, analysis: nil).destination
        #expect(destination.path == settings.outboxFolder.appendingPathComponent("Legal/mystery.pdf").path)
        #expect(!FileManager.default.fileExists(atPath: ReviewProposal.reasonURL(for: scan).path))
    }

    @Test func undoPutsTheScanBackWithItsReasonAndProposal() async throws {
        let scan = try reviewScan("scan3.pdf", proposal: Self.proposal())
        let pending = try #require(actions.pendingScans().first)
        let duplicates = DuplicateDetector(duplicatesFolder: settings.duplicatesFolder)
        let actions = ReviewActions(settings: settings, taxonomy: TestData.taxonomy,
                                    finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false,
                                                       remindersList: "x", expirationLeadDays: 30),
                                    index: DocumentIndex(url: temp.url.appendingPathComponent("index.jsonl")), duplicates: duplicates)
        let filing = try await actions.fileAsProposed(scan, document: pending.document!, analysis: pending.analysis!)
        let sha = BackfillApplier.sha256(try Data(contentsOf: filing.destination))
        #expect(duplicates.exactDuplicate(sha256: sha) != nil)

        let back = try actions.undo(filing)
        #expect(back == scan && FileManager.default.fileExists(atPath: scan.path))
        #expect(!FileManager.default.fileExists(atPath: filing.destination.path))
        #expect(actions.pendingScans().first?.reason == "Confidence 60% below threshold 70%.")
        #expect(actions.pendingScans().first?.document?.facets.vendor == "Toll_Authority")
        #expect(duplicates.exactDuplicate(sha256: sha) == nil)
    }

    @Test func sendBackToInboxMovesTheScanAndDropsSidecars() throws {
        let scan = try reviewScan("scan2.pdf", proposal: Self.proposal())
        let destination = try actions.sendBackToInbox(scan)
        #expect(destination.path == settings.inboxFolder.appendingPathComponent("scan2.pdf").path)
        #expect(!FileManager.default.fileExists(atPath: ReviewProposal.proposalURL(for: scan).path))
    }

    @Test func foldersIncludeTaxonomyAndExistingOnes() throws {
        try FileManager.default.createDirectory(at: settings.outboxFolder.appendingPathComponent("Hand Made Folder"),
                                                withIntermediateDirectories: true)
        let folders = actions.folders()
        #expect(folders.contains("Vehicle - Tolls") && folders.contains("Hand Made Folder"))
    }
}

@Suite struct UsageSummaryTests {
    @Test func groupsByMonthAndModel() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func at(_ day: String) -> Date { ISO8601DateFormatter().date(from: day + "T12:00:00Z")! }
        let entries = [
            UsageLedger.Entry(at: at("2026-03-02"), model: "claude-sonnet-5-5", input: 100, output: 10, cacheWrite: 50, cacheRead: 5, cost: 0.01),
            UsageLedger.Entry(at: at("2026-03-20"), model: "claude-sonnet-5-5", input: 100, output: 10, cacheWrite: 0, cacheRead: 0, cost: 0.02),
            UsageLedger.Entry(at: at("2026-04-01"), model: "future-model", input: 1, output: 1, cacheWrite: 0, cacheRead: 0, cost: nil)
        ]
        let summary = UsageSummary(entries, calendar: utc)
        #expect(summary.rows.map(\.id) == ["2026-03 claude-sonnet-5-5", "2026-04 future-model"])
        #expect(summary.rows[0].calls == 2 && summary.rows[0].inputTokens == 255 && summary.rows[0].cost == Decimal(string: "0.03"))
        #expect(summary.rows[1].cost == nil)
        #expect(summary.total == Decimal(string: "0.03"))
        // Unpriced calls don't count toward the average
        #expect(summary.rows[0].averageCost == Decimal(string: "0.015") && summary.rows[1].averageCost == nil)
        #expect(summary.averageCost == Decimal(string: "0.015"))
    }

    @Test func perScanCostsReadInCents() {
        #expect(UsageSummary.perScan(Decimal(string: "0.0183")!) == "1.8¢")
        #expect(UsageSummary.perScan(Decimal(string: "0.42")!) == "42¢")
        #expect(UsageSummary.perScan(Decimal(string: "1.25")!) == "$1.25")
    }
}

@Suite struct KeychainTests {
    @Test func apiKeysAreValidatedBeforeStoring() {
        #expect(Keychain.isValidKey("sk-ant-api03-abcdefghijklmnop_QRS-tuv"))
        #expect(!Keychain.isValidKey("sk-ant-short"))
        #expect(!Keychain.isValidKey("sk-ant-api03-abc def ghi jkl mno"))
        #expect(!Keychain.isValidKey("sk-ant-api03-abcdefghijk\nlmnop"))
        #expect(!Keychain.isValidKey("not-a-key-at-all-but-long"))
    }
}
