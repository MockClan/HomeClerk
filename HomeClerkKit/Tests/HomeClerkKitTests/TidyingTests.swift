import Foundation
import PDFKit
import Testing
@testable import HomeClerkKit

/// Fictional documents; nothing here comes from real ones.
@Suite struct TidyingTests {
    let temp = TempFolder()

    func entry(_ name: String, _ facets: DocumentFacets, folder: String = "Misc") throws -> DocumentIndex.Entry {
        let dir = temp.url.appendingPathComponent("Organized/\(folder)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try TestPDF.make(url, pages: [name])
        return DocumentIndex.Entry(path: url.path, source: "s.pdf", pages: [1, 1], model: "m", confidence: 0.9, summary: "",
                                   facets: facets)
    }

    @Test func filtersNarrowASearchOrStandAlone() throws {
        let library = DocumentLibrary(documents: [
            try entry("a.pdf", DocumentFacets(documentType: "Bill", vendor: "Acme_Power", documentDate: "2026-01-05", person: "Pat_Example")),
            try entry("b.pdf", DocumentFacets(documentType: "Receipt", vendor: "Acme_Tire", documentDate: "2025-06-19",
                                              vehicle: "2019_Example_Wagon"))
        ])
        #expect(library.find("acme", filter: .init(year: "2026")).map(\.facets.vendor) == ["Acme_Power"])
        #expect(library.find("", filter: .init(vehicle: "2019_Example_Wagon")).map(\.facets.vendor) == ["Acme_Tire"])
        #expect(library.find("", filter: .init()).isEmpty)
        #expect(library.years == ["2026", "2025"])
        #expect(library.choices(\.person) == ["Pat_Example"])
    }

    @Test func retentionListsDocumentsPastTheirKeepPeriod() throws {
        let rules = TestData.taxonomy.retention
        let utility = try entry("u.pdf", DocumentFacets(documentType: "Bill", area: "Utilities", documentDate: "2025-03-13"))
        let tax = try entry("t.pdf", DocumentFacets(documentType: "Tax Form", area: "Taxes", tags: ["w2"], documentDate: "2025-01-20"))
        let policy = try entry("p.pdf", DocumentFacets(documentType: "Policy", area: "Insurance", documentDate: "2010-01-01"))
        let expired = Retention.expired([utility, tax, policy], rules: rules, today: "2026-10-05")
        #expect(expired.map(\.entry.path) == [utility.path])
        #expect(expired.first?.keepUntil == "2026-03-13")
        #expect(Retention.expired([utility], rules: rules, today: "2026-10-05", keeping: [utility.path]).isEmpty)
        #expect(Retention.addYears("2024-02-29", 1) == "2025-02-28")
    }

    @Test func vehicleRecordsAreKeptButTollsAreNot() throws {
        let rules = TestData.taxonomy.retention
        let service = try entry("s.pdf", DocumentFacets(documentType: "Receipt", area: "Vehicle", documentDate: "2019-04-02"))
        let toll = try entry("t.pdf", DocumentFacets(documentType: "Bill", area: "Vehicle", tags: ["tolls"], documentDate: "2024-08-09"))
        #expect(Retention.expired([service, toll], rules: rules, today: "2026-10-05").map(\.entry.path) == [toll.path])
    }

    @Test func homeRecordsAreKeptButHOADuesAreNot() throws {
        let rules = TestData.taxonomy.retention
        let roof = try entry("r.pdf", DocumentFacets(documentType: "Receipt", area: "Home", documentDate: "2018-06-11"))
        let dues = try entry("d.pdf", DocumentFacets(documentType: "Bill", area: "Home", tags: ["hoa"], documentDate: "2024-02-01"))
        let bylaws = try entry("b.pdf", DocumentFacets(documentType: "Notice", area: "Home", tags: ["hoa"], documentDate: "2017-03-03"))
        #expect(Retention.expired([roof, dues, bylaws], rules: rules, today: "2026-10-05").map(\.entry.path) == [dues.path])
    }

    @Test func devicesAreKeptAndWorkExpensesGoAfterThreeYears() throws {
        let rules = TestData.taxonomy.retention
        let laptop = try entry("l.pdf", DocumentFacets(documentType: "Receipt", area: "Devices", documentDate: "2019-09-14"))
        let repair = try entry("w.pdf", DocumentFacets(documentType: "Record", area: "Devices", tags: ["work-expense"],
                                                       documentDate: "2022-11-30"))
        let hotel = try entry("h.pdf", DocumentFacets(documentType: "Receipt", area: "Shopping", tags: ["work-expense"],
                                                      documentDate: "2024-07-07"))
        #expect(Retention.expired([laptop, repair, hotel], rules: rules, today: "2026-10-05").map(\.entry.path) == [repair.path])
    }

    @Test func keepAllLikeThisAddsOneRulePerAreaAndType() throws {
        let gift = DocumentFacets(documentType: "Receipt", area: "Shopping", documentDate: "2024-05-05")
        let added = Retention.keepRules(like: [gift, gift, DocumentFacets(documentType: "receipt", area: "shopping"),
                                               DocumentFacets(documentType: "Statement", area: "")])
        #expect(added.map(\.condition) == [FacetCondition(area: "Shopping", types: ["Receipt"]), FacetCondition(types: ["Statement"])])
        #expect(added.allSatisfy { $0.keepYears == nil })
        let shopping = try entry("g.pdf", gift)
        #expect(!Retention.expired([shopping], rules: TestData.taxonomy.retention, today: "2026-10-05").isEmpty)
        #expect(Retention.expired([shopping], rules: added + TestData.taxonomy.retention, today: "2026-10-05").isEmpty)
    }

    @Test func taxPacketGathersTheYearAndEarlyFormsForIt() throws {
        let w2 = try entry("w2.pdf", DocumentFacets(documentType: "Tax Form", area: "Taxes", tags: ["w2"], documentDate: "2026-01-28"),
                           folder: "Taxes")
        let donation = try entry("d.pdf", DocumentFacets(documentType: "Receipt", area: "Charity", vendor: "Example_Food_Bank",
                                                          documentDate: "2025-12-02", amount: 50), folder: "Charitable Donations")
        let groceries = try entry("g.pdf", DocumentFacets(documentType: "Receipt", area: "Shopping", documentDate: "2025-05-05"))
        let late = try entry("late.pdf", DocumentFacets(documentType: "Tax Form", area: "Taxes", documentDate: "2026-07-01"))
        let picked = TaxPacket.documents([w2, donation, groceries, late], year: 2025, taxonomy: TestData.taxonomy)
        #expect(picked.map(\.path) == [donation.path, w2.path])

        let out = try TaxPacket.export(picked, year: 2025, to: temp.url, combinedPDF: true)
        #expect(out.lastPathComponent == "2025 Tax Documents")
        let csv = try String(contentsOf: out.appendingPathComponent("Index.csv"), encoding: .utf8)
        #expect(csv.contains("2025-12-02,Receipt,Example Food Bank,,50.00,,Charitable Donations/d.pdf"))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("Taxes/w2.pdf").path))
        #expect(PDFDocument(url: out.appendingPathComponent("All 2025 tax documents.pdf"))?.pageCount == 2)
        #expect(TaxPacket.csvField("a, \"b\"") == "\"a, \"\"b\"\"\"")
    }
}

@Suite struct DuplicatesAndSplitTests {
    let temp = TempFolder()
    var settings: HomeClerkSettings { HomeClerkSettings(values: ["basepath": .string(temp.url.path)]) }
    var actions: ReviewActions {
        ReviewActions(settings: settings, taxonomy: TestData.taxonomy,
                      finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "x",
                                         expirationLeadDays: 30),
                      index: DocumentIndex(url: temp.url.appendingPathComponent("index.jsonl")),
                      duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
    }

    @Test func listsDuplicatesWithTheirOriginalAndMovesOneToReview() throws {
        let original = settings.outboxFolder.appendingPathComponent("Bills - Utilities/bill.pdf")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TestPDF.make(original, pages: ["Bill"])
        try FileManager.default.createDirectory(at: settings.duplicatesFolder, withIntermediateDirectories: true)
        let copy = settings.duplicatesFolder.appendingPathComponent("scan.pdf")
        try TestPDF.make(copy, pages: ["Bill"])
        try "Duplicate of: Bills - Utilities/bill.pdf\nWhy: identical file\nmore".write(
            to: ReviewProposal.reasonURL(for: copy), atomically: true, encoding: .utf8)

        let item = try #require(actions.duplicateItems().first)
        #expect(item.original?.path == original.path && item.why == "identical file")

        let moved = try actions.notADuplicate(item)
        #expect(moved.deletingLastPathComponent().path == settings.reviewFolder.path)
        #expect(actions.pendingScans().first?.reason == "You said this isn't a duplicate of Bills - Utilities/bill.pdf.")
        #expect(actions.duplicateItems().isEmpty)
    }

    @Test func splittingFilesEachRangeAndUndoRestoresTheScan() async throws {
        try FileManager.default.createDirectory(at: settings.reviewFolder, withIntermediateDirectories: true)
        let scan = settings.reviewFolder.appendingPathComponent("two.pdf")
        try TestPDF.make(scan, pages: ["Bill page", "Receipt page"])
        let bill = FacetDocument(firstPage: 1, lastPage: 1, facets: DocumentFacets(documentType: "Bill", area: "Utilities",
            vendor: "Acme_Power", description: "Electric_Bill", documentDate: "2026-02-03"), confidence: 1)
        let receipt = FacetDocument(firstPage: 2, lastPage: 2, facets: DocumentFacets(documentType: "Receipt", area: "Shopping",
            vendor: "Acme_Store", description: "Supplies", documentDate: "2026-02-04"), confidence: 1)

        await #expect(throws: ReviewActions.SplitError.self) {
            try await actions.fileSplit(scan, documents: [FacetDocument(firstPage: 2, lastPage: 3, facets: DocumentFacets(), confidence: 1)],
                                        analysis: nil)
        }
        let split = try await actions.fileSplit(scan, documents: [bill, receipt], analysis: nil)
        #expect(split.parts.count == 2 && !FileManager.default.fileExists(atPath: scan.path))
        #expect(split.parts.allSatisfy { PDFDocument(url: $0.destination)?.pageCount == 1 })
        #expect(DocumentIndex(url: temp.url.appendingPathComponent("index.jsonl")).load().map(\.source) == ["review:two.pdf", "review:two.pdf"])

        try actions.undo(split)
        #expect(PDFDocument(url: scan)?.pageCount == 2)
        #expect(split.parts.allSatisfy { !FileManager.default.fileExists(atPath: $0.destination.path) })
    }
}

@Suite struct NeedsDetailsTests {
    let temp = TempFolder()

    func entry(_ folder: String, _ facets: DocumentFacets) throws -> DocumentIndex.Entry {
        let dir = temp.url.appendingPathComponent("Organized/\(folder)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).pdf")
        try TestPDF.make(url, pages: ["x"])
        return DocumentIndex.Entry(path: url.path, source: "s.pdf", pages: [1, 1], model: "m", confidence: 0.9, summary: "",
                                   facets: facets)
    }

    @Test func listsTheCatchAllAndDocumentsWithNothingToGoOn() throws {
        let catchAll = FilingRouter(TestData.taxonomy).folder(for: DocumentFacets())
        let bare = try entry(catchAll, DocumentFacets())
        let nameless = try entry("Bills - Utilities", DocumentFacets(documentType: "Bill", area: "Utilities"))
        let fine = try entry("Bills - Utilities", DocumentFacets(documentType: "Bill", area: "Utilities", vendor: "Acme_Power"))
        let library = DocumentLibrary(documents: [bare, nameless, fine])
        #expect(Set(library.needingDetails(taxonomy: TestData.taxonomy).map(\.path)) == [bare.path, nameless.path])
        #expect(library.needingDetails(taxonomy: TestData.taxonomy, leaving: [bare.path]).map(\.path) == [nameless.path])
    }
}

@Suite struct TidyingSafetyTests {
    let temp = TempFolder()
    var settings: HomeClerkSettings { HomeClerkSettings(values: ["basepath": .string(temp.url.path)]) }

    @Test func csvShowsFormulaLikeTextInsteadOfRunningIt() {
        #expect(TaxPacket.csvField("=HYPERLINK(\"x\")") == "\"'=HYPERLINK(\"\"x\"\")\"")
        #expect(TaxPacket.csvField("@SUM(A1)") == "'@SUM(A1)")
        #expect(TaxPacket.csvField("-12.50") == "-12.50")   // a number stays a number
        #expect(TaxPacket.csvField("Acme Power") == "Acme Power")
    }

    @Test func trashedDocumentsAreForgottenAndRememberedOnUndo() throws {
        let duplicates = DuplicateDetector(duplicatesFolder: settings.duplicatesFolder)
        let actions = ReviewActions(settings: settings, taxonomy: TestData.taxonomy,
                                    finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false,
                                                       remindersList: "x", expirationLeadDays: 30),
                                    index: DocumentIndex(url: temp.url.appendingPathComponent("index.jsonl")),
                                    duplicates: duplicates)
        let filed = settings.outboxFolder.appendingPathComponent("Receipts/r.pdf")
        try FileManager.default.createDirectory(at: filed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TestPDF.make(filed, pages: ["Receipt"])
        let sha = BackfillApplier.sha256(try Data(contentsOf: filed))
        actions.rememberFiled(filed, facets: DocumentFacets(vendor: "Acme_Store"))
        #expect(duplicates.exactDuplicate(sha256: sha) == "Receipts/r.pdf")
        actions.forgetFiled(filed)
        #expect(duplicates.exactDuplicate(sha256: sha) == nil)
    }

    @Test func aTrashedDocumentLeavesTheLibraryAndComesBackOnUndo() throws {
        let index = DocumentIndex(url: settings.basePath.appendingPathComponent(DocumentIndex.fileName))
        let actions = ReviewActions(settings: settings, taxonomy: TestData.taxonomy,
                                    finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false,
                                                       remindersList: "x", expirationLeadDays: 30),
                                    index: index, duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
        let filed = settings.outboxFolder.appendingPathComponent("Pay Stubs/p.pdf")
        try FileManager.default.createDirectory(at: filed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TestPDF.make(filed, pages: ["Pay stub"])
        try index.append(DocumentIndex.Entry(path: filed.path, source: "p.pdf", pages: [1], model: "test", confidence: 1,
                                             summary: "", facets: DocumentFacets(documentType: "Pay Stub")))
        let parked = temp.url.appendingPathComponent("trashed.pdf")
        try FileManager.default.moveItem(at: filed, to: parked)
        actions.forgetFiled(filed)
        #expect(LibraryHealth.scan(settings: settings, index: index).issues.isEmpty)

        try FileManager.default.moveItem(at: parked, to: filed)
        actions.rememberFiled(filed, facets: nil)
        #expect(DocumentLibrary.load(index).documents.map(\.path) == [filed.path])
        #expect(LibraryHealth.scan(settings: settings, index: index).issues.isEmpty)
    }
}

@Suite struct RotateTests {
    let temp = TempFolder()

    @Test func quarterTurnsRetainPageGeometryAndKeepText() throws {
        let url = temp.url.appendingPathComponent("scan.pdf")
        try TestPDF.make(url, pages: ["Upside down page", "Second page"])
        try PDFTools.rotate(url, pages: [0], quarterTurns: 1)
        let rotated = try #require(PDFDocument(url: url))
        let first = try #require(rotated.page(at: 0)), second = try #require(rotated.page(at: 1))
        #expect(first.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))
        #expect(second.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))   // untouched
        #expect(first.rotation == 90)                                                     // retain the original page content
        #expect(rotated.string?.contains("Upside down page") == true)

        // Four quarter turns come back to where they started
        try PDFTools.rotate(url, pages: nil, quarterTurns: 3)
        #expect(PDFDocument(url: url)?.page(at: 0)?.rotation == 0)
        #expect(PDFDocument(url: url)?.page(at: 1)?.rotation == 270)
    }
}

@Suite struct FullTextTests {
    let temp = TempFolder()

    func filed(_ name: String, _ pages: [String]) throws -> DocumentIndex.Entry {
        let url = temp.url.appendingPathComponent("Organized/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TestPDF.make(url, pages: pages)
        return DocumentIndex.Entry(path: url.path, source: "s", pages: [], model: "m", confidence: 1, summary: "",
                                   facets: DocumentFacets(vendor: "Acme_Power"))
    }

    @Test func findsWordsPrintedOnThePageWithASnippet() throws {
        let bill = try filed("bill.pdf", ["ACME POWER", "Meter number 4471-B serves the garage"])
        let other = try filed("other.pdf", ["Nothing to see"])
        let index = FullTextIndex(folder: temp.url.appendingPathComponent(".homeclerk-cache"))
        let matches = index.search("GARAGE meter", in: [bill, other])
        #expect(matches.map(\.entry.path) == [bill.path])
        #expect(matches.first?.snippet.contains("serves the garage") == true)
        #expect(index.search("garage basement", in: [bill]).isEmpty)

        // Cached, and read again from the cache by a new index
        let cacheFile = temp.url.appendingPathComponent(".homeclerk-cache/\(FullTextIndex.fileName)")
        #expect(FileManager.default.fileExists(atPath: cacheFile.path))
        let mode = try FileManager.default.attributesOfItem(atPath: cacheFile.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(FullTextIndex(folder: temp.url.appendingPathComponent(".homeclerk-cache")).search("garage", in: [bill]).count == 1)
    }

    @Test func accentsAndCaseDontMatter() {
        #expect(FullTextIndex.fold("Électricité\nDUE") == "electricite due")
    }
}

@Suite struct CombineTests {
    let temp = TempFolder()
    var settings: HomeClerkSettings { HomeClerkSettings(values: ["basepath": .string(temp.url.path)]) }
    var actions: ReviewActions {
        ReviewActions(settings: settings, taxonomy: TestData.taxonomy,
                      finisher: Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "x",
                                         expirationLeadDays: 30),
                      index: DocumentIndex(url: temp.url.appendingPathComponent("index.jsonl")),
                      duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
    }

    @Test func joinsScansInOrderAndUndoBringsThemBack() throws {
        try FileManager.default.createDirectory(at: settings.reviewFolder, withIntermediateDirectories: true)
        let fronts = settings.reviewFolder.appendingPathComponent("scan_01.pdf")
        let backs = settings.reviewFolder.appendingPathComponent("scan_02.pdf")
        try TestPDF.make(fronts, pages: ["Page one", "Page three"])
        try TestPDF.make(backs, pages: ["Page two"])
        try "Unsure".write(to: ReviewProposal.reasonURL(for: backs), atomically: true, encoding: .utf8)

        let combination = try actions.combine([fronts, backs])
        let joined = try #require(PDFDocument(url: combination.scan))
        #expect(joined.pageCount == 3 && joined.page(at: 2)?.string?.contains("Page two") == true)
        #expect(actions.pendingScans().map(\.url.lastPathComponent) == ["scan_01_2.pdf"]) // Published while the originals still exist.
        #expect(actions.pendingScans().first?.reason.hasPrefix("Combined from 2 scans") == true)

        try actions.undo(combination)
        #expect(Set(actions.pendingScans().map(\.url.lastPathComponent)) == ["scan_01.pdf", "scan_02.pdf"])
        #expect(PDFDocument(url: fronts)?.pageCount == 2)
        #expect(actions.pendingScans().first { $0.url.lastPathComponent == "scan_02.pdf" }?.reason == "Unsure")
    }
}

@Suite struct HistoryTests {
    let temp = TempFolder()

    @Test func keepsEntriesNewestFirstAndTrims() throws {
        let log = HistoryLog(folder: temp.url)
        for i in 1...5 {
            log.append(.init(at: Date(timeIntervalSince1970: Double(i) * 60), kind: .filed, title: "doc\(i).pdf", detail: "Receipts",
                             path: "/x/doc\(i).pdf", engine: "Claude test"))
        }
        log.append(.init(kind: .review, title: "unsure.pdf", detail: "Confidence 50% below threshold 70%."))
        #expect(log.recent(3).map(\.title) == ["unsure.pdf", "doc5.pdf", "doc4.pdf"])
        #expect(log.recent().first?.kind == .review && log.recent().last?.engine == "Claude test")
        let mode = try FileManager.default.attributesOfItem(atPath: log.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        log.trim(keep: 2)
        #expect(log.recent().map(\.title) == ["unsure.pdf", "doc5.pdf"])
    }
}

@Suite struct OriginalsTests {
    let temp = TempFolder()

    @Test func legacyCopiesAreRetainedEvenWhenScannerNamesMatch() throws {
        let folder = temp.url.appendingPathComponent("_originals")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func original(_ name: String, daysAgo: Double) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try TestPDF.make(url, pages: [name])
            try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path)
            return url
        }
        let old = try original("scan0001.pdf", daysAgo: 200)
        let oldSecond = try original("scan0001_2.pdf", daysAgo: 150)
        _ = try original("scan0002.pdf", daysAgo: 30)            // filed, but recent
        _ = try original("scan0003.pdf", daysAgo: 200)           // never filed (in Review, say)
        let fromReview = try original("scan0004.pdf", daysAgo: 120)
        func entry(_ source: String) -> DocumentIndex.Entry {
            DocumentIndex.Entry(path: "/x/\(source).pdf", source: source, pages: [], model: "m", confidence: 1, summary: "",
                                facets: DocumentFacets())
        }
        let clearable = Originals.clearable(in: folder, documents: [entry("scan0001.pdf"), entry("scan0002.pdf"),
                                                                   entry("review:scan0004.pdf")])
        #expect(clearable.isEmpty)
        for original in [old, oldSecond, fromReview] { #expect(FileManager.default.fileExists(atPath: original.path)) }
    }
}
