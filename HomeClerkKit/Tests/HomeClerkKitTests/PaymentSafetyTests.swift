import Foundation
import Testing
@testable import HomeClerkKit

@Suite struct PaymentSafetyTests {
    let temp = TempFolder()

    func bill(_ path: String, person: String = "Alice", vehicle: String = "", pet: String = "") -> DocumentIndex.Entry {
        DocumentIndex.Entry(path: path, source: "scan.pdf", pages: [1, 1], model: "test", confidence: 1, summary: "",
            facets: DocumentFacets(documentType: "Bill", vendor: "Acme", documentDate: "2030-03-01",
                                  dueDate: "2030-03-20", amount: 100, person: person, vehicle: vehicle, pet: pet))
    }

    func receipt(_ path: String, person: String = "Alice", vehicle: String = "", pet: String = "") -> DocumentIndex.Entry {
        var result = bill(path, person: person, vehicle: vehicle, pet: pet)
        result.facets.documentType = "Receipt"
        result.facets.documentDate = "2030-03-15"
        result.facets.dueDate = ""
        return result
    }

    var marks: PaidMarks { PaidMarks(url: temp.url.appendingPathComponent(PaidMarks.fileName)) }
    var finisher: Finisher { Finisher(makeSearchable: false, applyTags: false, createReminders: false, remindersList: "test", expirationLeadDays: 30) }

    @Test func marksBelongToOneBillEvenWhenAllItsFacetsMatch() throws {
        let alice = bill("alice.pdf"), bob = bill("bob.pdf", person: "Bob"), another = bill("another.pdf")
        try marks.set(true, for: alice)
        #expect(marks.mark(for: bob) == nil && marks.mark(for: another) == nil)
        try marks.set(false, for: bob)
        try marks.set(nil, for: another)
        #expect(marks.mark(for: alice) == true && marks.mark(for: bob) == false)
        try marks.set(nil, for: alice)
        #expect(marks.mark(for: alice) == nil && marks.mark(for: bob) == false)
    }

    @Test func aReusedPathDoesNotReuseOrOverwriteAnotherBillsMark() throws {
        var first = bill("same.pdf")
        let second = bill("same.pdf")
        try marks.set(true, for: first)
        #expect(marks.mark(for: second) == nil)
        try marks.set(false, for: second)
        first.path = "renamed.pdf"
        first.facets.vendor = "Corrected vendor"
        first.facets.dueDate = "2030-04-01"
        first.facets.amount = 150
        #expect(marks.mark(for: first) == true && marks.mark(for: second) == false)
    }

    @Test(arguments: ["person", "vehicle", "pet"])
    func incompatibleSubjectsDoNotPayEachOthersBills(field: String) {
        let due = bill("bill.pdf", vehicle: "RAV4", pet: "Biscuit")
        var paid = receipt("receipt.pdf", vehicle: "RAV4", pet: "Biscuit")
        switch field {
        case "person": paid.facets.person = "Bob"
        case "vehicle": paid.facets.vehicle = "Civic"
        default: paid.facets.pet = "Mittens"
        }
        let library = DocumentLibrary(documents: [due, paid])
        #expect(Bills.receiptMatches(library.documents).isEmpty)
        #expect(library.payments(marks: nil)[due.path] == .unpaid)
        #expect(library.spending(from: "2030-03-01", to: "2030-03-31", by: .vendor).first?.amount == 200)
    }

    /// Most receipts name no one: with only one car and pet in this vendor's documents, a receipt
    /// that doesn't say which still pays the bill.
    @Test(arguments: ["missingVehicle", "missingPet"])
    func aReceiptThatNamesNoOneFitsAVendorWithOneSubject(field: String) {
        let due = bill("bill.pdf", vehicle: "RAV4", pet: "Biscuit")
        var paid = receipt("receipt.pdf", vehicle: "RAV4", pet: "Biscuit")
        if field == "missingVehicle" { paid.facets.vehicle = "" } else { paid.facets.pet = "" }
        let library = DocumentLibrary(documents: [due, paid])
        #expect(Bills.receiptMatches(library.documents) == [due.path: paid.path])
        #expect(library.payments(marks: nil)[due.path]?.isPaid == true)
    }

    /// Two cars on one insurer: a receipt that doesn't say which car is only a suggestion, even
    /// when just one car's bill is waiting this month.
    @Test func aReceiptThatNamesNoOneNeedsConfirmingWhenTheVendorCoversSeveral() {
        let due = bill("bill.pdf", vehicle: "RAV4")
        var earlier = bill("civic.pdf", vehicle: "Civic")
        earlier.facets.dueDate = "2029-09-01"
        earlier.facets.documentDate = "2029-08-15"
        var paid = receipt("receipt.pdf")
        paid.facets.vehicle = ""
        let library = DocumentLibrary(documents: [due, earlier, paid])
        #expect(Bills.receiptMatches(library.documents).isEmpty)
        #expect(library.payments(marks: nil)[due.path] == .unpaid)
    }

    @Test func matchingSubjectsNormalizeNamesAndPayOnlyTheRightMember() {
        let alice = bill("alice.pdf", person: "Alice_Smith"), bob = bill("bob.pdf", person: "Bob_Smith")
        var paid = receipt("receipt.pdf", person: "ALICE SMITH")
        paid.facets.vendor = "ACME."
        #expect(Bills.receiptMatches([alice, bob, paid]) == [alice.path: paid.path])
    }

    @Test func aReceiptPaysTheBillDueClosestToItRegardlessOfOrder() {
        let first = bill("first.pdf")                     // due Mar 20; the receipt is 5 days before
        var next = bill("next.pdf")
        next.facets.documentDate = "2030-03-10"
        next.facets.dueDate = "2030-04-01"                // 17 days after the receipt
        let paid = receipt("receipt.pdf")
        #expect(Bills.receiptMatches([first, next, paid]) == [first.path: paid.path])
        #expect(Bills.receiptMatches([paid, next, first]) == [first.path: paid.path])
    }

    @Test func aReceiptEquallyCloseToTwoBillsIsAmbiguousRegardlessOfOrder() {
        var first = bill("first.pdf")
        first.facets.dueDate = "2030-03-10"               // 5 days before the receipt
        let next = bill("next.pdf")                       // due Mar 20, 5 days after
        let paid = receipt("receipt.pdf")
        #expect(Bills.receiptMatches([first, next, paid]).isEmpty)
        #expect(Bills.receiptMatches([paid, next, first]).isEmpty)
    }

    /// A receipt equally close to two bills is set aside, but a bill that also has a clear receipt
    /// of its own is still paid by it.
    @Test func aTieSetsAsideOnlyTheContestedReceipt() {
        var first = bill("first.pdf")
        first.facets.dueDate = "2030-03-10"
        let second = bill("second.pdf")                   // due Mar 20
        let contested = receipt("contested.pdf")          // Mar 15: 5 days from each
        var own = receipt("own.pdf")
        own.facets.documentDate = "2030-03-25"            // 5 days after the second bill only
        #expect(Bills.receiptMatches([first, second, contested, own]) == [second.path: own.path])
    }

    /// Two months of a fixed bill, each paid on time: each receipt pays its own month. With
    /// March's receipt missing, April's pays April and March stays unpaid.
    @Test func monthsOfAFixedBillPairUpMonthByMonth() {
        let march = bill("march.pdf")
        var april = bill("april.pdf")
        april.facets.documentDate = "2030-04-01"
        april.facets.dueDate = "2030-04-20"
        let paidMarch = receipt("paid-march.pdf")         // Mar 15
        var paidApril = receipt("paid-april.pdf")
        paidApril.facets.documentDate = "2030-04-16"
        #expect(Bills.receiptMatches([march, april, paidMarch, paidApril]) == [march.path: paidMarch.path, april.path: paidApril.path])
        // The losing pairing (March's bill with April's receipt) is settled, not left for review
        let proposals = BillIndex([march, april, paidMarch, paidApril]).proposals
        #expect(proposals.count == 2 && proposals.allSatisfy { $0.status == .automatic })
        #expect(Bills.receiptMatches([march, april, paidApril]) == [april.path: paidApril.path])
    }

    @Test func receiptCannotPayAFutureIssuedBill() {
        let march = bill("march.pdf")
        var april = bill("april.pdf")
        april.facets.documentDate = "2030-04-01"
        april.facets.dueDate = "2030-04-20"
        let paid = receipt("receipt.pdf")
        #expect(Bills.receiptMatches([april, paid]).isEmpty)
        #expect(Bills.receiptMatches([march, april, paid]) == [march.path: paid.path])
    }

    @Test func twoReceiptsForOneBillAreAmbiguousAndAReceiptCannotPayItself() {
        let due = bill("bill.pdf")
        var one = receipt("one.pdf")
        let two = receipt("two.pdf")
        #expect(Bills.receiptMatches([due, one, two]).isEmpty)
        one.facets.dueDate = "2030-03-20"
        #expect(Bills.receiptMatches([one]).isEmpty)
    }

    func legacy(_ entry: DocumentIndex.Entry) throws -> DocumentIndex.Entry {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        object["document_id"] = nil
        return try JSONDecoder().decode(DocumentIndex.Entry.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func documentIdentityPersistsAndLegacyDecodingIsRepeatable() throws {
        var original = bill("bill.pdf")
        original.filedAt = Date(timeIntervalSince1970: 0)
        #expect(try JSONDecoder().decode(DocumentIndex.Entry.self, from: JSONEncoder().encode(original)) == original)
        let old = try legacy(original), again = try legacy(original)
        #expect(old.documentID == again.documentID)
        let restored = try JSONDecoder().decode(DocumentIndex.Entry.self, from: JSONEncoder().encode(old))
        #expect(restored.documentID == old.documentID)
    }

    @Test func legacyMarksNeverFallBackToVendorAmountOrANewFileAtTheOldPath() throws {
        let old = try legacy(bill("old.pdf"))
        let mark = PaidMarks.Mark(paid: true, identity: "acme|2030-03-20|100", at: .now)
        try PrivateFile.writeJSON([old.path: mark], to: marks.url)
        #expect(marks.mark(for: old) == true)
        #expect(marks.mark(for: try legacy(bill("bob.pdf", person: "Bob"))) == nil)
        #expect(marks.mark(for: bill("old.pdf")) == nil)
        try marks.migrateLegacyMark(for: old)
        var renamed = old; renamed.path = "renamed.pdf"; renamed.facets.amount = 101
        #expect(marks.mark(for: renamed) == true)
    }

    @Test func refilingAndUndoKeepLegacyPaymentIdentityAfterCorrections() async throws {
        let settings = HomeClerkSettings(values: ["basepath": .string(temp.url.path)])
        let folder = settings.outboxFolder.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scan = folder.appendingPathComponent("bill.pdf")
        try TestPDF.make(scan, pages: ["Bill"])
        let old = try legacy(bill(scan.path))
        let index = DocumentIndex(url: temp.url.appendingPathComponent(DocumentIndex.fileName))
        try index.append(old)
        try PrivateFile.writeJSON([old.path: PaidMarks.Mark(paid: true, identity: "old fallback", at: .now)], to: marks.url)
        let actions = ReviewActions(settings: settings, taxonomy: TestData.taxonomy, finisher: finisher, index: index,
                                    duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
        var facets = old.facets; facets.amount = 150; facets.dueDate = "2030-04-01"
        let result = try await actions.refile(old, facets: facets, folder: "Medical")
        let current = try #require(DocumentLibrary.load(index).documents.first)
        #expect(current.documentID == old.documentID && marks.mark(for: current) == true)
        try await actions.undo(result)
        #expect(marks.mark(for: try #require(DocumentLibrary.load(index).documents.first)) == true)
    }

    @Test func returnToReviewAndRefilingKeepPaymentIdentity() async throws {
        let settings = HomeClerkSettings(values: ["basepath": .string(temp.url.path)])
        let folder = settings.outboxFolder.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scan = folder.appendingPathComponent("bill.pdf")
        try TestPDF.make(scan, pages: ["Bill"])
        let old = bill(scan.path)
        let index = DocumentIndex(url: temp.url.appendingPathComponent(DocumentIndex.fileName))
        try index.append(old)
        try marks.set(true, for: old)
        let actions = ReviewActions(settings: settings, taxonomy: TestData.taxonomy, finisher: finisher, index: index,
                                    duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
        let returned = try actions.returnToReview(old)
        let proposal = try #require(ReviewProposal.load(for: returned.scan))
        #expect(proposal.documentID == old.documentID)
        _ = try await actions.fileEdited(returned.scan, facets: old.facets, folder: "Medical", analysis: proposal, confidence: 1)
        let current = try #require(DocumentLibrary.load(index).documents.first)
        #expect(current.documentID == old.documentID && marks.mark(for: current) == true)
    }

    @Test func backfillAndUndoKeepPaymentIdentity() async throws {
        let settings = HomeClerkSettings(values: ["basepath": .string(temp.url.path)])
        let folder = settings.outboxFolder.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scan = folder.appendingPathComponent("bill.pdf")
        try TestPDF.make(scan, pages: ["Bill"])
        let old = bill(scan.path)
        let index = DocumentIndex(url: temp.url.appendingPathComponent(DocumentIndex.fileName))
        try index.append(old)
        try marks.set(true, for: old)
        var entry = BackfillEntry(path: "Other/bill.pdf", sha256: BackfillApplier.sha256(try Data(contentsOf: scan)), handCorrected: false)
        entry.apply = true; entry.action = .move; entry.proposedFolder = "Medical"; entry.proposedName = "renamed.pdf"
        entry.facets = old.facets; entry.facets?.amount = 150
        let plan = BackfillPlan(createdAt: .now, organizedFolder: settings.outboxFolder.path, model: "test", entries: [entry])
        let result = try await BackfillApplier(finisher: finisher, index: index,
            duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder)).apply(plan, undoFolder: temp.url)
        #expect(result.problems.isEmpty)
        let current = try #require(DocumentLibrary.load(index).documents.first)
        #expect(current.documentID == old.documentID && marks.mark(for: current) == true)
        _ = try BackfillApplier.undo(result.undoLog, organized: settings.outboxFolder)
        #expect(marks.mark(for: try #require(DocumentLibrary.load(index).documents.first)) == true)
    }
}
