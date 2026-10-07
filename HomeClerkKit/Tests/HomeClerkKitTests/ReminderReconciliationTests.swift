import Foundation
import Testing
@testable import HomeClerkKit

struct ReminderReconciliationTests {
    @Test func correctionKeepsOverduePaymentDatesInsteadOfRemovingTheReminder() {
        let facets = DocumentFacets(vendor: "Example", dueDate: "2020-01-01", amount: 10)
        #expect(FinishingPlan.reminders(facets, filePath: "/bill.pdf", today: "2026-10-06", expirationLeadDays: 30).isEmpty)
        let sync = FinishingPlan.reminders(facets, filePath: "/bill.pdf", today: "2026-10-06",
            expirationLeadDays: 30, includingOverduePayments: true)
        #expect(sync.first?.due == "2020-01-01" && sync.first?.kind == .payment)
    }
    func item(_ kind: ReminderItem.Kind = .payment, path: String = "/archive/bill.pdf", due: String = "2099-12-01") -> ReminderItem {
        .init(title: kind == .payment ? "Pay Example $10" : "Policy expires", due: due,
              notes: "Bill from Example", filePath: path, kind: kind)
    }
    func existing(_ item: ReminderItem, id: String, documentID: String? = nil, completed: Bool = false) -> ReminderReconciliation.Existing {
        .init(id: id, title: item.title, due: item.due,
              notes: item.notes + (documentID.map { "\n" + ReminderReconciliation.marker($0, item.kind) } ?? ""),
              path: item.filePath, completed: completed)
    }

    @Test func renameAndDateChangeUpdateTheSameCompletedReminderAndRetryIsIdempotent() throws {
        let old = item(), new = item(path: "/archive/renamed.pdf", due: "2099-12-15")
        let saved = existing(old, id: "reminder", documentID: "document", completed: true)
        let plan = try ReminderReconciliation.plan(.init(documentID: "document", items: [new]), existing: [saved])
        #expect(plan.saves.count == 1 && plan.removes.isEmpty)
        #expect(plan.saves.first?.existingID == "reminder")
        #expect(plan.saves.first?.item == new)
        let updated = existing(new, id: saved.id, documentID: "document", completed: saved.completed)
        #expect(updated.completed)
        #expect(try ReminderReconciliation.plan(.init(documentID: "document", items: [new]), existing: [updated]).saves.isEmpty)
        let undo = try ReminderReconciliation.plan(.init(documentID: "document", items: [old]), existing: [updated])
        #expect(undo.saves.first?.existingID == "reminder" && undo.saves.first?.item == old)
    }

    @Test func aReminderMadeBeforeTheRenameIsUpdatedNotDuplicated() throws {
        let current = item()
        var saved = existing(current, id: "reminder")
        saved.notes = current.notes + "\n" + ReminderReconciliation.marker("document", .payment, app: "DocuSort")
        let plan = try ReminderReconciliation.plan(.init(documentID: "document", items: [current]), existing: [saved])
        #expect(plan.removes.isEmpty && plan.saves.map(\.existingID) == ["reminder"])
        #expect(plan.saves.first?.notes.hasSuffix(ReminderReconciliation.marker("document", .payment)) == true)
    }

    @Test func removedDatesRemoveOnlyThatDocumentsManagedRoles() throws {
        let payment = existing(item(), id: "pay", documentID: "one")
        let expiry = existing(item(.expiration), id: "expiry", documentID: "one")
        let unrelated = existing(item(), id: "other", documentID: "two")
        let personal = existing(item(), id: "personal")
        let plan = try ReminderReconciliation.plan(.init(documentID: "one", items: []), existing: [payment, expiry, unrelated, personal])
        #expect(Set(plan.removes) == ["pay", "expiry"] && plan.saves.isEmpty)
    }

    @Test func legacyMigrationRequiresEveryFieldAndRefusesAmbiguity() throws {
        let old = item(), new = item(path: "/archive/new.pdf")
        let legacy = existing(old, id: "legacy", completed: true)
        var personal = legacy; personal.id = "personal"; personal.notes = "My own reminder"
        let request = ReminderReconciliation.Request(documentID: "stable", items: [new], previous: [old])
        let plan = try ReminderReconciliation.plan(request, existing: [legacy, personal])
        #expect(plan.saves.first?.existingID == "legacy")
        #expect(plan.saves.first?.notes.hasSuffix(ReminderReconciliation.marker("stable", .payment)) == true)
        var duplicate = legacy; duplicate.id = "duplicate"
        #expect(throws: ReminderReconciliation.Ambiguous.self) {
            try ReminderReconciliation.plan(request, existing: [legacy, duplicate])
        }
        var wrongPath = legacy; wrongPath.path = "/another/bill.pdf"
        #expect(try ReminderReconciliation.plan(request, existing: [personal, wrongPath]).saves.first?.existingID == nil)
    }

    @Test func paymentAndExpirationAreIndependentAndOtherIDsNeverMatch() throws {
        let old = existing(item(), id: "old", documentID: "other")
        let request = ReminderReconciliation.Request(documentID: "new", items: [item(), item(.expiration)])
        let plan = try ReminderReconciliation.plan(request, existing: [old])
        #expect(plan.saves.count == 2 && plan.saves.allSatisfy { $0.existingID == nil })
        #expect(Set(plan.saves.map(\.notes)).count == 2)
    }

    @Test func failedEditSyncPersistsMigrationContextAndRetryUsesCurrentDetails() async throws {
        let temp = TempFolder()
        var settings = HomeClerkSettings(basePath: temp.url)
        settings.createReminders = true; settings.applyFinderTags = false
        try FileManager.default.createDirectory(at: settings.outboxFolder, withIntermediateDirectories: true)
        let file = settings.outboxFolder.appendingPathComponent("old.pdf")
        try TestPDF.make(file, pages: ["Synthetic bill"])
        let index = DocumentIndex(url: temp.url.appendingPathComponent(DocumentIndex.fileName))
        let facets = DocumentFacets(documentType: "Bill", area: "Utilities", vendor: "Example", dueDate: "2099-12-01", amount: 10)
        let old = DocumentIndex.Entry(path: file.path, source: "scan.pdf", pages: [1, 1], model: "test", confidence: 1, summary: "", facets: facets)
        try index.append(old)
        var worker = Finisher(settings)
        let archive = temp.url
        worker.operations = .init(searchable: { _ in }, tags: { _, _ in }, reminders: { request, _ in
            let pending = try #require(FinishingIssues(folder: archive).load().first)
            #expect(pending.documentID == request.documentID)
            #expect(pending.reminderPrevious?.first?.filePath == old.path)
            throw CocoaError(.fileWriteUnknown)
        })
        let warnings = Locked<[String]>([])
        let actions = ReviewActions(settings: settings, taxonomy: TestData.taxonomy, finisher: worker, index: index,
            duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder), warnings: { warning in warnings.mutate { $0.append(warning) } })
        var corrected = facets; corrected.dueDate = "2099-12-15"; corrected.vendor = "Corrected"
        let refiled = try await actions.refile(old, facets: corrected, folder: nil)
        let store = FinishingIssues(folder: temp.url)
        let pending = try #require(store.load().first)
        #expect(pending.documentID == old.documentID && pending.reminderPrevious?.first?.filePath == old.path)
        #expect(!warnings.value.isEmpty && FileManager.default.fileExists(atPath: refiled.after.path))
        let requests = Locked<[ReminderReconciliation.Request]>([])
        worker.operations.reminders = { request, _ in requests.mutate { $0.append(request) }; return [] }
        _ = try await store.retry(documentID: old.documentID, settings: settings, index: index, finisher: worker)
        #expect(requests.value.first?.items.first?.due == "2099-12-15")
        #expect(requests.value.first?.items.first?.filePath == refiled.after.path)
        #expect(requests.value.first?.previous.first?.filePath == old.path)
        #expect(try store.load().isEmpty)
        // Undo reconciles back to the original date/path, while retaining the same document ID.
        let undoActions = ReviewActions(settings: settings, taxonomy: TestData.taxonomy, finisher: worker, index: index,
            duplicates: DuplicateDetector(duplicatesFolder: settings.duplicatesFolder))
        try await undoActions.undo(refiled)
        #expect(requests.value.last?.items.first?.filePath == old.path)
        #expect(requests.value.last?.items.first?.due == facets.dueDate)
    }

    /// A registration that expired yesterday: correcting its document keeps the open reminder,
    /// while clearing the expiration date still removes it.
    @Test func aLapsedExpirationKeepsItsReminderThroughACorrection() throws {
        let facets = DocumentFacets(vendor: "Example_DMV", description: "Registration", expiresOn: "2030-03-09", vehicle: "Civic")
        let lapsed = FinishingPlan.lapsedReminderKinds(facets, today: "2030-03-10")
        #expect(lapsed == [.expiration])
        let existing = ReminderReconciliation.Existing(id: "r1", title: "Civic: Registration expires Mar 9, 2030", due: "2030-02-07",
            notes: "Registration from Example DMV\n" + ReminderReconciliation.marker("doc-1", .expiration), path: "/x.pdf", completed: false)
        let wanted = FinishingPlan.reminders(facets, filePath: "/x.pdf", today: "2030-03-10", expirationLeadDays: 30,
                                             includingOverduePayments: true)
        let kept = try ReminderReconciliation.plan(.init(documentID: "doc-1", items: wanted, lapsed: lapsed), existing: [existing])
        #expect(kept.removes.isEmpty)
        let cleared = try ReminderReconciliation.plan(.init(documentID: "doc-1", items: [], lapsed: []), existing: [existing])
        #expect(cleared.removes == ["r1"])
    }
}

