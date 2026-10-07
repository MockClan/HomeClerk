import Foundation
import Testing
@testable import HomeClerkKit

@Suite struct BillsTests {
    let temp = TempFolder()

    func doc(_ name: String, _ type: String, vendor: String, date: String = "", due: String = "", amount: String?,
             area: String = "Home") throws -> DocumentIndex.Entry {
        DocumentIndex.Entry(path: try temp.file(name).path, source: "s.pdf", pages: [1, 1], model: "m", confidence: 0.9, summary: "",
                            facets: DocumentFacets(documentType: type, area: area, vendor: vendor, documentDate: date, dueDate: due,
                                                   amount: amount.flatMap { Decimal(string: $0) }))
    }

    @Test func receiptsPayOnlyTheBillAlreadyIssuedWithinTheDateWindow() throws {
        let march = try doc("march.pdf", "Bill", vendor: "Lakeside_Water", date: "2030-03-01", due: "2030-03-20", amount: "48.60")
        let april = try doc("april.pdf", "Bill", vendor: "Lakeside_Water", date: "2030-04-01", due: "2030-04-20", amount: "48.60")
        let other = try doc("other.pdf", "Bill", vendor: "Lakeside_Water", date: "2030-03-01", due: "2030-03-20", amount: "51.10")
        // Spelled differently, same vendor
        let receipt = try doc("paid.pdf", "Receipt", vendor: "LAKESIDE WATER", date: "2030-03-15", amount: "48.60")
        let tooLate = try doc("late.pdf", "Receipt", vendor: "Lakeside_Water", date: "2030-09-01", amount: "48.60")
        let matches = Bills.receiptMatches([march, april, other, receipt, tooLate])
        #expect(matches == [march.path: receipt.path])
    }

    @Test func handMarksOverrideReceiptsAndFollowRenames() throws {
        let bill = try doc("bill.pdf", "Bill", vendor: "Lakeside_Water", due: "2030-03-20", amount: "48.60")
        let receipt = try doc("paid.pdf", "Receipt", vendor: "Lakeside_Water", date: "2030-03-18", amount: "48.60")
        let unmatched = try doc("gas.pdf", "Statement", vendor: "Prairie_Gas", due: "2030-03-25", amount: "77.05")
        let marks = PaidMarks(url: temp.url.appendingPathComponent(PaidMarks.fileName))
        var library = DocumentLibrary(documents: [bill, receipt, unmatched])

        #expect(library.payments(marks: marks) == [bill.path: .receipt(receipt.path), unmatched.path: .unpaid])
        try marks.set(false, for: bill)
        try marks.set(true, for: unmatched)
        #expect(library.payments(marks: marks) == [bill.path: .unpaid, unmatched.path: .markedPaid])

        // Renamed by Edit Details: the persistent document ID keeps its mark.
        var renamed = unmatched
        renamed.path = try temp.file("renamed.pdf").path
        library = DocumentLibrary(documents: [bill, receipt, renamed])
        #expect(library.payments(marks: marks)[renamed.path] == .markedPaid)

        try marks.set(nil, for: bill)
        #expect(library.payments(marks: marks)[bill.path] == .receipt(receipt.path))
        let mode = try FileManager.default.attributesOfItem(atPath: marks.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func upcomingShowsUnpaidOverdueBillsOnly() throws {
        let unpaid = try doc("unpaid.pdf", "Bill", vendor: "Prairie_Gas", due: "2030-03-05", amount: "77.05")
        let paid = try doc("paid.pdf", "Bill", vendor: "Lakeside_Water", due: "2030-03-06", amount: "48.60")
        let tooOld = try doc("old.pdf", "Bill", vendor: "Prairie_Gas", due: "2029-12-05", amount: "70.00")
        let next = try doc("next.pdf", "Bill", vendor: "Prairie_Gas", due: "2030-03-25", amount: "75.00")
        let library = DocumentLibrary(documents: [unpaid, paid, tooOld, next])
        let payments: [String: BillPayment] = [unpaid.path: .unpaid, paid.path: .markedPaid, tooOld.path: .unpaid, next.path: .unpaid]
        let items = library.upcoming(from: "2030-03-10", to: "2030-04-10", payments: payments, overdueFrom: "2030-02-01")
        #expect(items.map(\.path) == [unpaid.path, next.path])
        #expect(items.map(\.payment) == [.unpaid, .unpaid])
    }

    @Test func higherThanUsualNeedsHistoryAndAMeaningfulJump() throws {
        let history = try ["01", "02", "03", "04"].enumerated().map { i, month in
            try doc("h\(i).pdf", "Bill", vendor: "Prairie_Gas", date: "2030-\(month)-01", amount: ["70.00", "74.00", "72.00", "90.00"][i])
        }
        let spike = try doc("spike.pdf", "Bill", vendor: "Prairie_Gas", date: "2030-05-01", amount: "112.00")
        let normal = try doc("normal.pdf", "Bill", vendor: "Prairie_Gas", date: "2030-05-02", amount: "81.35")
        let documents = history + [spike, normal]
        #expect(Bills.usualAmount(before: spike, in: documents) == 73)   // median of 70, 72, 74, 90
        #expect(Bills.higherThanUsual(spike, in: documents) == 73)
        #expect(Bills.higherThanUsual(normal, in: documents) == nil)
        // Too little history
        #expect(Bills.higherThanUsual(history[2], in: documents) == nil)
        // A quarter more but under $10 isn't worth a mention
        let small = try ["01", "02", "03"].enumerated().map { i, month in
            try doc("s\(i).pdf", "Bill", vendor: "Tiny_Co", date: "2030-\(month)-01", amount: "8.00")
        }
        let smallSpike = try doc("ss.pdf", "Bill", vendor: "Tiny_Co", date: "2030-04-01", amount: "16.00")
        #expect(Bills.higherThanUsual(smallSpike, in: small + [smallSpike]) == nil)
    }

    @Test func spendingCountsBillsAndUnmatchedReceiptsByMonth() throws {
        let bill = try doc("bill.pdf", "Bill", vendor: "Lakeside_Water", date: "2030-03-01", due: "2030-03-20", amount: "48.60")
        let paying = try doc("paid.pdf", "Receipt", vendor: "Lakeside_Water", date: "2030-03-18", amount: "48.60")
        let store = try doc("store.pdf", "Receipt", vendor: "Corner_Hardware", date: "2030-03-09", amount: "19.99", area: "Home")
        let vet = try doc("vet.pdf", "Receipt", vendor: "Maple_Vet", date: "2030-04-02", amount: "120.00", area: "Pets")
        let statement = try doc("card.pdf", "Statement", vendor: "Big_Bank", date: "2030-03-28", amount: "900.00")
        let outside = try doc("old.pdf", "Receipt", vendor: "Corner_Hardware", date: "2029-11-09", amount: "5.00")
        let library = DocumentLibrary(documents: [bill, paying, store, vet, statement, outside])

        let byVendor = library.spending(from: "2030-01-01", to: "2030-12-31", by: .vendor)
        #expect(byVendor.map(\.id) == ["2030-03 Lakeside Water", "2030-03 Corner Hardware", "2030-04 Maple Vet"])
        #expect(byVendor.map(\.amount) == [Decimal(string: "48.60")!, Decimal(string: "19.99")!, 120])

        let byArea = library.spending(from: "2030-01-01", to: "2030-12-31", by: .area)
        #expect(byArea.map(\.id) == ["2030-03 Home", "2030-04 Pets"])
        #expect(byArea.first?.amount == Decimal(string: "68.59"))
        #expect(byArea.first?.documents == 2)
    }
}

@Suite struct LocalDayTests {
    @Test func aDayIsMidnightOnThisMacsCalendar() throws {
        let date = try #require(FinishingPlan.localDay("2030-03-01"))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: date)
        #expect(parts == DateComponents(year: 2030, month: 3, day: 1, hour: 0))
        #expect(FinishingPlan.localDay("2030-02-30") == nil)
    }
}

@Suite struct WeeklyDigestTests {
    func item(_ date: String, _ kind: UpcomingItem.Kind, _ title: String) -> UpcomingItem {
        UpcomingItem(date: date, kind: kind, title: title, path: "/x/\(title).pdf")
    }

    @Test func overdueBillsComeFirstByName() throws {
        let digest = try #require(WeeklyDigest.compose(
            items: [item("2030-03-12", .due, "Prairie Gas $77.05 — Gas Bill"),
                    item("2030-03-03", .due, "Lakeside Water $48.60 — Water Bill"),
                    item("2030-03-14", .expires, "Biscuit: Rabies Certificate (Maple Vet)")],
            today: "2030-03-10", waitingScans: 0, waitingSince: nil, namesToConfirm: 1))
        #expect(digest.title == "This week: 1 bill overdue, 1 bill due, 1 document expiring")
        #expect(digest.body == """
            Overdue: Lakeside Water $48.60 — Water Bill
            Prairie Gas $77.05 — Gas Bill
            Biscuit: Rabies Certificate (Maple Vet)
            1 name to confirm in Review
            """)
        #expect(!digest.opensReview)
    }

    @Test func aQuietWeekSaysNothingAndWaitingWorkOpensReview() throws {
        #expect(WeeklyDigest.compose(items: [], today: "2030-03-10", waitingScans: 0, waitingSince: nil, namesToConfirm: 0) == nil)
        let digest = try #require(WeeklyDigest.compose(items: [], today: "2030-03-10", waitingScans: 2, waitingSince: nil,
                                                       namesToConfirm: 0))
        #expect(digest.title == "This week: 2 scans waiting in Review")
        #expect(digest.opensReview)
    }
}

@Suite struct FilingNoteTests {
    let temp = TempFolder()

    func doc(_ name: String, _ type: String, date: String, due: String = "", amount: String) throws -> DocumentIndex.Entry {
        DocumentIndex.Entry(path: try temp.file(name).path, source: "s.pdf", pages: [1, 1], model: "m", confidence: 0.9, summary: "",
                            facets: DocumentFacets(documentType: type, area: "Utilities", vendor: "Prairie_Gas",
                                                   documentDate: date, dueDate: due, amount: Decimal(string: amount)))
    }

    @Test func notesAPayingReceiptUnlessMarkedByHand() throws {
        let bill = try doc("bill.pdf", "Bill", date: "2030-03-01", due: "2030-03-20", amount: "77.05")
        let receipt = try doc("receipt.pdf", "Receipt", date: "2030-03-18", amount: "77.05")
        let marks = PaidMarks(url: temp.url.appendingPathComponent(PaidMarks.fileName))
        #expect(Bills.filingNote(for: receipt.path, in: [bill, receipt], marks: marks) == "Pays the Prairie Gas bill due 2030-03-20")
        try marks.set(true, for: bill)
        #expect(Bills.filingNote(for: receipt.path, in: [bill, receipt], marks: marks) == nil)
        #expect(Bills.filingNote(for: bill.path, in: [bill, receipt], marks: marks) == nil)
    }

    @Test func notesAHigherBill() throws {
        let history = try (1...3).map { try doc("h\($0).pdf", "Bill", date: "2030-0\($0)-01", amount: "70.00") }
        let spike = try doc("spike.pdf", "Bill", date: "2030-04-01", amount: "101.15")
        #expect(Bills.filingNote(for: spike.path, in: history + [spike], marks: nil)
                == "Higher than usual: Prairie Gas is usually about $70.00")
    }
}

@Suite struct BillScaleTests {
    /// Thousands of filed documents: Upcoming's work stays well under a second.
    @Test func aLargeLibraryStaysQuick() {
        var documents: [DocumentIndex.Entry] = []
        for i in 0..<6000 {
            let month = String(format: "%02d", i % 12 + 1), vendor = "Vendor_\(i % 150)"
            let type = i % 3 == 0 ? "Receipt" : "Bill"
            documents.append(DocumentIndex.Entry(path: "/library/\(i).pdf", source: "s.pdf", pages: [1, 1], model: "m",
                                                 confidence: 0.9, summary: "",
                                                 facets: DocumentFacets(documentType: type, vendor: vendor,
                                                                        documentDate: "2030-\(month)-01",
                                                                        dueDate: type == "Bill" ? "2030-\(month)-20" : "",
                                                                        amount: Decimal(i % 40 + 20))))
        }
        let library = DocumentLibrary(documents: documents)
        let start = Date()
        let payments = library.payments(marks: nil)
        let items = library.upcoming(from: "2030-01-01", to: "2030-12-31", payments: payments)
        _ = library.spending(from: "2030-01-01", to: "2030-12-31", by: .vendor)
        #expect(!items.isEmpty)
        // A second here; GitHub's shared virtual Macs run debug builds a few times slower. Either way
        // far under the 14 s this took before bills were indexed by vendor.
        #expect(Date().timeIntervalSince(start) < (OCRAvailability.onCI ? 5 : 1))
    }
}

@Suite struct PaymentReminderTitleTests {
    @Test func namesTheVendorAndAmount() {
        #expect(FinishingPlan.paymentReminderTitle(DocumentFacets(vendor: "Prairie_Gas", amount: Decimal(string: "77.05")))
                == "Pay Prairie Gas $77.05")
        #expect(FinishingPlan.paymentReminderTitle(DocumentFacets(vendor: "Prairie_Gas")) == nil)
    }
}

@Suite struct SpendingCSVTests {
    @Test func oneRowPerMonthAndGroupWithFormulasDefused() {
        let rows = [SpendingRow(month: "2030-03", group: "Lakeside Water", amount: Decimal(string: "48.6")!, documents: 1),
                    SpendingRow(month: "2030-03", group: "=Corner, Hardware", amount: 1234, documents: 2)]
        #expect(SpendingRow.csv(rows, grouping: .vendor) == """
            Month,Vendor,Amount,Documents
            2030-03,Lakeside Water,48.60,1
            2030-03,"'=Corner, Hardware",1234.00,2

            """)
    }
}

@Suite struct BackupCheckTests {
    @Test func iCloudDriveFoldersCount() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(BackupCheck.isInICloudDrive(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/HomeClerk")))
    }

    @Test func aTemporaryFolderIsntInICloud() {
        #expect(!BackupCheck.isInICloudDrive(FileManager.default.temporaryDirectory))
    }
}

@Suite struct LibraryLoadScaleTests {
    /// Loading the index happens on the main thread after every change, so it must stay quick:
    /// 6,000 documents took 2.1 s in a debug build before date formatters were reused.
    @Test func sixThousandDocumentsLoadQuickly() throws {
        let temp = TempFolder()
        let index = DocumentIndex(url: temp.url.appendingPathComponent("index.jsonl"))
        let folder = temp.url.appendingPathComponent("Organized")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entries = (0..<6000).map { i -> DocumentIndex.Entry in
            let path = folder.appendingPathComponent("\(i).pdf")
            FileManager.default.createFile(atPath: path.path, contents: Data("x".utf8))
            return .init(path: path.path, source: "s.pdf", pages: [1, 1], model: "m", confidence: 0.9, summary: "A fictional summary.",
                         facets: DocumentFacets(documentType: "Bill", area: "Utilities", vendor: "Vendor_\(i % 150)",
                                                documentDate: "2030-01-01", dueDate: "2030-01-20", amount: 42))
        }
        try index.append(entries)
        let start = Date()
        #expect(DocumentLibrary.load(index).documents.count == 6000)
        #expect(Date().timeIntervalSince(start) < (OCRAvailability.onCI ? 6 : 1.5))
    }
}

@Suite struct YearInReviewTests {
    let temp = TempFolder()

    func doc(_ name: String, _ type: String, _ vendor: String, date: String, due: String = "", amount: String? = nil,
             area: String = "Utilities", expires: String = "", pet: String = "") throws -> DocumentIndex.Entry {
        DocumentIndex.Entry(path: try temp.file(name).path, source: "s.pdf", pages: [1, 1], model: "m", confidence: 0.9, summary: "",
                            facets: DocumentFacets(documentType: type, area: area, vendor: vendor, description: "Statement",
                                                   documentDate: date, dueDate: due, expiresOn: expires,
                                                   amount: amount.flatMap { Decimal(string: $0) }, pet: pet))
    }

    @Test func summarizesAYear() throws {
        let documents = [
            try doc("g29.pdf", "Bill", "Prairie_Gas", date: "2029-02-01", due: "2029-02-20", amount: "61.40"),
            try doc("g1.pdf", "Bill", "Prairie_Gas", date: "2030-02-01", due: "2030-02-20", amount: "75.00"),
            try doc("g1r.pdf", "Receipt", "Prairie_Gas", date: "2030-02-18", amount: "75.00"),      // on time
            try doc("g2.pdf", "Bill", "Prairie_Gas", date: "2030-03-01", due: "2030-03-20", amount: "75.00"),
            try doc("g2r.pdf", "Receipt", "Prairie_Gas", date: "2030-03-25", amount: "75.00"),      // late
            try doc("hw.pdf", "Receipt", "Corner_Hardware", date: "2030-03-09", amount: "19.99", area: "Home"),
            try doc("rab.pdf", "Certificate", "Maple_Vet", date: "2029-06-01", area: "Pet", expires: "2030-06-01", pet: "Biscuit"),
        ]
        let review = YearInReview(year: 2030, library: DocumentLibrary(documents: documents))
        #expect(review.documents == 5)
        #expect(review.byArea.first == .init(name: "Utilities", count: 4))
        #expect(review.busiestMonth == .init(name: "2030-03", count: 3))
        #expect(review.spent == Decimal(string: "169.99"))        // two bills + the unmatched hardware receipt
        #expect(review.topVendors.map(\.name) == ["Prairie Gas", "Corner Hardware"])
        #expect(review.billsPaidByReceipt == 2 && review.paidOnTime == 1)
        #expect(review.priceRises.map(\.vendor) == ["Prairie Gas"])
        #expect(review.priceRises.first.map { Int(($0.increase * 100).rounded()) } == 22)   // 61.40 → 75.00
        #expect(review.expired == ["Biscuit: Statement (2030-06-01)"])
        #expect(review.text.contains("Paid on time: 1 of 2 bills with a receipt"))
        #expect(YearInReview.years(in: DocumentLibrary(documents: documents)) == [2030, 2029])
    }
}
