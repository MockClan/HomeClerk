import Foundation
import Testing
@testable import HomeClerkKit

struct ReceiptDecisionTests {
    let temp = TempFolder()
    var store: ReceiptDecisions { ReceiptDecisions(folder: temp.url) }
    func bill(_ name: String, person: String = "Alice") -> DocumentIndex.Entry {
        .init(path: name, source: "scan", pages: [1, 1], model: "test", confidence: 1, summary: "",
              facets: .init(documentType: "Bill", vendor: "Example", documentDate: "2030-03-01", dueDate: "2030-03-20", amount: 100, person: person))
    }
    func receipt(_ name: String, person: String = "Alice") -> DocumentIndex.Entry {
        var entry = bill(name, person: person)
        entry.facets.documentType = "Receipt"; entry.facets.dueDate = ""; entry.facets.documentDate = "2030-03-15"
        return entry
    }

    @Test func ambiguityIsExplainedAndConfirmationPaysOnlyTheChosenBill() throws {
        let a = bill("a.pdf"), b = bill("b.pdf"), r = receipt("receipt.pdf")
        let documents = [a, b, r]
        let proposed = BillIndex(documents)
        #expect(proposed.receiptMatches.isEmpty && proposed.proposals.count == 2)
        #expect(proposed.proposals.allSatisfy { $0.status == .suggested && $0.reasons.contains { $0.contains("More than one") } })
        try store.set(true, billID: a.documentID, receiptID: r.documentID)
        let saved = try store.snapshot()
        let library = DocumentLibrary(documents: documents)
        #expect(BillIndex(documents, decisions: saved).receiptMatches == [a.path: r.path])
        #expect(library.payments(marks: nil, decisions: saved)[a.path] == .receipt(r.path))
        #expect(library.payments(marks: nil, decisions: saved)[b.path] == .unpaid)
        #expect(library.spending(from: "2030-03-01", to: "2030-03-31", by: .vendor, decisions: saved).first?.amount == 200)
    }

    @Test func rejectedPairStaysRejectedAcrossReloadRenameAndReanalysis() throws {
        var b = bill("old-bill.pdf"), r = receipt("old-receipt.pdf")
        try store.set(false, billID: b.documentID, receiptID: r.documentID)
        b.path = "renamed-bill.pdf"; r.path = "renamed-receipt.pdf"
        b.facets.vendor = "Corrected"; r.facets.vendor = "Corrected"
        let saved = try ReceiptDecisions(folder: temp.url).snapshot()
        let index = BillIndex([b, r], decisions: saved)
        #expect(index.receiptMatches.isEmpty && index.proposals.first?.status == .rejected)
        let library = DocumentLibrary(documents: [b, r])
        #expect(library.spending(from: "2030-03-01", to: "2030-03-31", by: .vendor, decisions: saved).first?.amount == 200)
        #expect(Bills.filingNote(for: r.path, in: [b, r], marks: nil, decisions: saved) == nil)
    }

    @Test func subjectDifferencesRequireConfirmationAndConfirmedIDsSurviveDetailChanges() throws {
        var b = bill("bill.pdf"), r = receipt("receipt.pdf", person: "Bob")
        let suggested = BillIndex([b, r])
        #expect(suggested.receiptMatches.isEmpty)
        #expect(suggested.proposals.first?.reasons.contains { $0.contains("Person differs") } == true)
        try store.set(true, billID: b.documentID, receiptID: r.documentID)
        b.path = "corrected.pdf"; b.facets.vendor = "Renamed vendor"; b.facets.amount = 120
        let index = BillIndex([b, r], decisions: try store.snapshot())
        #expect(index.receiptMatches == [b.path: r.path] && index.proposals.first?.status == .confirmed)
        #expect(index.proposals.first?.reasons.contains { $0.contains("no longer meet") } == true)
    }

    @Test func oneToOneConflictsDoNotOverwriteHistoryAndUndoRefusesLaterDecisions() throws {
        let a = bill("a"), b = bill("b"), r = receipt("r"), other = receipt("other")
        let change = try store.set(true, billID: a.documentID, receiptID: r.documentID)
        let url = temp.url.appendingPathComponent(ReceiptDecisions.fileName)
        let bytes = try Data(contentsOf: url)
        #expect(throws: ReceiptDecisions.Conflict.self) { try store.set(true, billID: b.documentID, receiptID: r.documentID) }
        #expect(throws: ReceiptDecisions.Conflict.self) { try store.set(true, billID: a.documentID, receiptID: other.documentID) }
        #expect(try Data(contentsOf: url) == bytes)
        try store.undo(change)
        #expect(try store.snapshot().records.isEmpty)
        let first = try store.set(false, billID: a.documentID, receiptID: r.documentID)
        try store.set(true, billID: a.documentID, receiptID: r.documentID)
        #expect(throws: ReceiptDecisions.Changed.self) { try store.undo(first) }
    }

    @Test func resetUndoRestoresDecisionsAndRefusesAConflictingNewLink() throws {
        let a = bill("a"), b = bill("b"), r = receipt("r")
        try store.set(true, billID: a.documentID, receiptID: r.documentID)
        let reset = try store.set(nil, billID: a.documentID, receiptID: r.documentID)
        try store.undo(reset)
        #expect(try store.snapshot().decision(billID: a.documentID, receiptID: r.documentID) == true)
        let resetAgain = try store.set(nil, billID: a.documentID, receiptID: r.documentID)
        try store.set(true, billID: b.documentID, receiptID: r.documentID)
        #expect(throws: ReceiptDecisions.Conflict.self) { try store.undo(resetAgain) }
        #expect(try store.snapshot().decision(billID: b.documentID, receiptID: r.documentID) == true)
    }

    @Test func corruptStoreIsPreservedAndUnavailableHistoryDisablesReceiptInference() throws {
        let b = bill("b"), r = receipt("r")
        let url = temp.url.appendingPathComponent(ReceiptDecisions.fileName)
        let corrupt = Data("not JSON".utf8); try PrivateFile.write(corrupt, to: url)
        #expect(throws: (any Error).self) { try store.snapshot() }
        #expect(throws: (any Error).self) { try store.set(false, billID: b.documentID, receiptID: r.documentID) }
        #expect(try Data(contentsOf: url) == corrupt)
        let library = DocumentLibrary(documents: [b, r])
        #expect(library.payments(marks: nil, decisions: .unavailable)[b.path] == .unpaid)
        #expect(library.spending(from: "2030-03-01", to: "2030-03-31", by: .vendor, decisions: .unavailable).first?.amount == 200)
        let marks = PaidMarks(url: temp.url.appendingPathComponent(PaidMarks.fileName)); try marks.set(true, for: b)
        #expect(library.payments(marks: marks, decisions: .unavailable)[b.path] == .markedPaid)
    }

    @Test func dormantConfirmationDoesNotReassignItsReceiptAndReusedPathsDoNotInheritIt() throws {
        let a = bill("same.pdf"), b = bill("b.pdf"), r = receipt("receipt.pdf")
        try store.set(true, billID: a.documentID, receiptID: r.documentID, billName: a.path, receiptName: r.path)
        let snapshot = try store.snapshot()
        #expect(snapshot.records.first?.billName == a.path && snapshot.records.first?.receiptName == r.path)
        #expect(BillIndex([b, r], decisions: snapshot).receiptMatches.isEmpty)
        let replacement = bill("same.pdf")
        #expect(BillIndex([replacement, r], decisions: snapshot).receiptMatches.isEmpty)
        try store.set(nil, billID: a.documentID, receiptID: r.documentID)
        #expect(BillIndex([replacement, r], decisions: try store.snapshot()).receiptMatches == [replacement.path: r.path])
    }

    @Test func manualPaidMarksWinAndStatementLinksDoNotEraseReceiptSpending() throws {
        var b = bill("b"), r = receipt("r")
        try store.set(true, billID: b.documentID, receiptID: r.documentID)
        let saved = try store.snapshot()
        let marks = PaidMarks(url: temp.url.appendingPathComponent(PaidMarks.fileName)); try marks.set(false, for: b)
        #expect(DocumentLibrary(documents: [b, r]).payments(marks: marks, decisions: saved)[b.path] == .unpaid)
        b.facets.documentType = "Statement"
        #expect(DocumentLibrary(documents: [b, r]).spending(from: "2030-03-01", to: "2030-03-31", by: .vendor, decisions: saved).first?.amount == 100)
        b.facets.documentType = "Bill"; b.facets.documentDate = "2030-02-31"
        #expect(DocumentLibrary(documents: [b, r]).spending(from: "2030-03-01", to: "2030-03-31", by: .vendor, decisions: saved).first?.amount == 100)
    }

    @Test func privatePermissionsAndMalformedConflictingHistoryAreValidated() throws {
        let a = bill("a"), b = bill("b"), r = receipt("r")
        try store.set(true, billID: a.documentID, receiptID: r.documentID)
        let url = temp.url.appendingPathComponent(ReceiptDecisions.fileName)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let records = try store.snapshot().records + [.init(billID: b.documentID, receiptID: r.documentID, confirmed: true, revision: UUID(), at: Date())]
        try PrivateFile.writeJSON(records, to: url)
        #expect(throws: (any Error).self) { try store.snapshot() }
    }

    @Test func cancelledPaymentUpdateStopsBeforeRequestingRemindersAccess() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await Reminders.setPaymentDone(true, bill: .init(amount: 100), path: "/synthetic.pdf", inList: "Synthetic")
                return false
            } catch is CancellationError { return true }
            catch { Issue.record("Unexpected cancellation result: \(error)"); return false }
        }
        #expect(await task.value)
    }
}
