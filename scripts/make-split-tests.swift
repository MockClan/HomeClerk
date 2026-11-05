// Makes the split test set: made-up household documents scanned together, to measure how well a
// reader tells where one document ends and the next begins.
//
//   swift scripts/make-split-tests.swift [folder]          default ~/HomeClerk-TestData-Split
//   swift run --package-path HomeClerkKit homeclerk-dev eval --dir ~/HomeClerk-TestData-Split --analyzer ollama
//
// Every vendor, name, number, and date here is invented. Pages are images, like a real scan, so the
// reader has to OCR them.

import AppKit
import CryptoKit

let outFolder = URL(fileURLWithPath: NSString(string: CommandLine.arguments.dropFirst().first ?? "~/HomeClerk-TestData-Split")
    .expandingTildeInPath)
let width = 1275, height = 1650   // US Letter at 150 dpi

/// A line of a page: text and its size, or a gap.
enum Line { case text(String, CGFloat), gap }

func t(_ s: String, _ size: CGFloat = 26) -> Line { .text(s, size) }
func row(_ label: String, _ value: String) -> Line {
    .text(label.padding(toLength: 40, withPad: " ", startingAt: 0) + value, 24)
}

/// One scanned-looking page: dark gray text, slightly tilted, on a not-quite-white page.
func page(_ lines: [Line], tilt: CGFloat) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.setFillColor(gray: 0.985, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
    context.rotate(by: tilt * .pi / 180)
    context.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    var y = CGFloat(height) - 110
    for line in lines {
        switch line {
        case .gap: y -= 34
        case .text(let s, let size):
            let monospaced = s.contains("  $") || s.contains("   ")
            let font = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
            y -= size * 1.55
            NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(white: 0.12, alpha: 1)])
                .draw(at: CGPoint(x: 110, y: y))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()!
}

struct Doc {
    var pages: [[Line]]
    var expected: [String: Any]
}

// The documents
let docs: [String: Doc] = [
    "water_bill": Doc(pages: [[
        t("LAKESIDE WATER", 44), t("Municipal Water & Sewer Service", 22), .gap,
        t("STATEMENT DATE: May 21, 2026"), t("ACCOUNT: 40-7731-2"), t("SERVICE ADDRESS: 18 Example Lane"), .gap,
        t("Service period  Apr 10 – May 9, 2026", 24), .gap,
        row("Water usage (4,200 gal)", "$31.20"), row("Sewer", "$16.48"), row("Base charge", "$4.50"), .gap,
        t("AMOUNT DUE  $52.18", 34), t("PAYMENT DUE BY  June 3, 2026", 30), .gap,
        t("Thank you for conserving water.", 22),
    ]], expected: ["document_type": "Bill", "area": "Utilities", "vendor": "Lakeside Water",
                   "document_date": "2026-05-21", "amount": 52.18]),

    "vet_receipt": Doc(pages: [[
        t("MAPLE STREET VETERINARY", 42), t("Companion Animal Hospital", 22), .gap,
        t("RECEIPT", 34), t("Date: 04/22/2026"), t("Patient: Juniper (canine)"), t("Client: Pat Example"), .gap,
        row("Wellness exam", "$58.00"), row("Rabies vaccine (3 yr)", "$28.40"), .gap,
        t("TOTAL PAID  $86.40", 32), t("Paid by card ending 0042", 24), .gap,
        t("Next visit: annual exam, April 2027", 22),
    ]], expected: ["document_type": "Receipt", "area": "Pet", "vendor": "Maple Street Veterinary",
                   "document_date": "2026-04-22", "amount": 86.40]),

    "bank_statement": Doc(pages: [[
        t("SUMMIT RIDGE CREDIT UNION", 40), t("Member Account Statement", 24), .gap,
        t("Statement period: March 1 – March 31, 2026"), t("Member: Pat Example"), t("Account: Share Savings ending 5517"), .gap,
        row("Beginning balance", "$2,410.00"), row("Deposits", "$1,250.00"), row("Withdrawals", "$640.35"),
        row("Dividends", "$1.92"), row("Ending balance", "$3,021.57"), .gap,
        t("Page 1 of 2", 20),
    ], [
        t("SUMMIT RIDGE CREDIT UNION", 30), t("Account activity (continued)", 24), .gap,
        row("03/02  Payroll deposit", "$625.00"), row("03/09  Grocery - Fresh Basket", "-$118.22"),
        row("03/16  Payroll deposit", "$625.00"), row("03/21  Transfer to checking", "-$400.00"),
        row("03/28  Card - Corner Hardware", "-$122.13"), row("03/31  Dividend", "$1.92"), .gap,
        t("Page 2 of 2", 20),
    ]], expected: ["document_type": "Statement", "area": "Financial", "vendor": "Summit Ridge Credit Union",
                   "document_date": "2026-03-31"]),

    "insurance_renewal": Doc(pages: [[
        t("HARBOR SHIELD INSURANCE", 40), t("Homeowners Policy - Renewal Declarations", 24), .gap,
        t("Policy number: HS-220-48817"), t("Named insured: Pat Example"), t("Issued: February 10, 2026"),
        t("Policy period: March 15, 2026 - March 15, 2027"), .gap,
        row("Dwelling coverage", "$410,000"), row("Personal property", "$205,000"), row("Liability", "$300,000"),
        row("Deductible", "$1,500"), row("Annual premium", "$1,388.00"), .gap,
        t("This is not a bill. Your premium will be billed separately.", 22),
    ]], expected: ["document_type": "Policy", "area": "Insurance", "tags": ["home"], "vendor": "Harbor Shield Insurance",
                   "document_date": "2026-02-10"]),

    "auto_repair": Doc(pages: [[
        t("PINE VALLEY AUTO SERVICE", 40), t("Repair Order #RO-58213"), .gap,
        t("Date: January 24, 2026"), t("Vehicle: 2017 Example Wagon   Mileage: 84,310", 24), .gap,
        row("Front brake pads and rotors", "$248.00"), row("Brake fluid flush", "$49.95"), row("Shop supplies", "$14.80"), .gap,
        t("TOTAL  $312.75", 32), t("PAID IN FULL - Visa"), .gap,
        t("Warranty: 12 months / 12,000 miles on parts and labor.", 22),
    ]], expected: ["document_type": "Receipt", "area": "Vehicle", "vendor": "Pine Valley Auto Service",
                   "document_date": "2026-01-24", "amount": 312.75]),

    // Related: an invoice and the receipt for paying it. One document.
    "invoice_and_receipt": Doc(pages: [[
        t("NORTHWIND ELECTRONICS", 40), t("INVOICE #4471", 30), .gap,
        t("Invoice date: March 5, 2026"), t("Bill to: Pat Example"), .gap,
        row("27-inch monitor", "$189.99"), row("Monitor arm", "$30.00"), .gap,
        t("TOTAL DUE  $219.99", 32), t("Due on receipt", 24),
    ], [
        t("NORTHWIND ELECTRONICS", 40), t("PAYMENT RECEIPT", 30), .gap,
        t("Received: March 7, 2026"), t("Applied to invoice #4471"), .gap,
        t("Amount paid  $219.99", 30), t("Balance  $0.00"), .gap,
        t("Thank you for your purchase.", 22),
    ]], expected: ["area": "Devices", "vendor": "Northwind Electronics", "amount": 219.99]),

    // Related: a letter and the form it encloses. One document.
    "school_letter": Doc(pages: [[
        t("RIVERSIDE SCHOOL DISTRICT", 38), t("Office of the Principal - Oak Hollow Elementary", 22), .gap,
        t("September 2, 2026"), .gap, t("Dear Parent or Guardian,"), .gap,
        t("Fourth grade will visit the Science Center on September 25.", 24),
        t("Enclosed is the permission form for the trip. Please sign it and", 24),
        t("return it with your student by September 18.", 24), .gap,
        t("Sincerely,", 24), t("R. Okafor, Principal", 24),
    ], [
        t("FIELD TRIP PERMISSION FORM", 34), t("Oak Hollow Elementary - Science Center, Sept. 25, 2026", 22), .gap,
        t("Student name: ______________________________"), t("Teacher: __________________"), .gap,
        t("I give permission for my child to attend.", 24), .gap,
        t("Parent/guardian signature: ____________________"), t("Emergency phone: __________________"),
    ]], expected: ["area": "Education", "vendor": "Riverside School District"]),

    // Related: a repair invoice, then the shop's inspection checklist from the same visit, which
    // carries no name, date, or vehicle of its own. One document.
    "service_with_checklist": Doc(pages: [[
        t("BRIGHTWAY TIRE & SERVICE", 40), t("Invoice #77-30418"), .gap,
        t("Customer: Pat Example"), t("Vehicle: 2015 Example Hatchback   Miles: 96,204", 24),
        t("Invoice date: 08/21/2026"), .gap,
        row("Synthetic oil change", "$64.95"), row("Tire rotation", "$0.00"), row("Cabin air filter", "$29.50"), .gap,
        t("Page 1 of 2", 20),
    ], [
        t("BRIGHTWAY TIRE & SERVICE", 40), t("Invoice #77-30418 - Payment"), .gap,
        row("Subtotal", "$94.45"), row("Tax", "$4.91"), row("Total", "$99.36"), .gap,
        t("PAID - card ending 0042"), t("Customer signature: ____________________"), .gap,
        t("Page 2 of 2", 20),
    ], [
        t("MULTI-POINT INSPECTION", 36), t("Green = OK   Yellow = Soon   Red = Now", 22), .gap,
        row("Brake pads - front", "[ ]G [ ]Y [ ]R"), row("Brake pads - rear", "[ ]G [ ]Y [ ]R"),
        row("Tire tread depth", "____ /32"), row("Wipers", "[ ]G [ ]Y [ ]R"), row("Battery test", "[ ]G [ ]Y [ ]R"),
        row("Belts and hoses", "[ ]G [ ]Y [ ]R"), .gap,
        t("Technician notes: ______________________________"), t("Inspected by: ______________"),
    ]], expected: ["document_type": "Receipt", "area": "Vehicle", "vendor": "Brightway Tire & Service",
                   "document_date": "2026-08-21", "amount": 99.36]),

    // Related: a receipt, then the shop's inspection form with the visit's date filled in. One document.
    "service_with_dated_form": Doc(pages: [[
        t("RIDGELINE QUICK LUBE", 40), t("Receipt #Q-55190"), .gap,
        t("Customer: Pat Example"), t("Date: 03/12/2026"), .gap,
        row("Full synthetic oil change", "$79.99"), row("Wiper blades", "$32.00"), row("Tax", "$5.82"), .gap,
        t("TOTAL PAID  $117.81", 32), t("Visa ending 0042"),
    ], [
        t("VEHICLE INSPECTION REPORT", 36), t("Date: 03/12/2026", 24), .gap,
        row("Brakes", "[x]OK  [ ]Soon  [ ]Now"), row("Tires", "[x]OK  [ ]Soon  [ ]Now"),
        row("Fluids", "[ ]OK  [x]Soon  [ ]Now"), row("Lights", "[x]OK  [ ]Soon  [ ]Now"), .gap,
        t("Technician: ____________"),
    ]], expected: ["document_type": "Receipt", "area": "Vehicle", "vendor": "Ridgeline Quick Lube",
                   "document_date": "2026-03-12", "amount": 117.81]),

    // A program that ends at its printed last page, then an unrelated handwritten-style note
    "exercise_program": Doc(pages: [[
        t("Willow Creek Physical Therapy", 34), t("Home Exercise Program for Pat Example"), t("Date: 02/18/2026"), .gap,
        t("1. Bridges - 3 sets of 10", 24), t("2. Clamshells - 3 sets of 12", 24), t("3. Wall sits - hold 30 seconds", 24), .gap,
        t("Page 1 of 2", 20),
    ], [
        t("Willow Creek Physical Therapy", 34), t("Home Exercise Program (continued)"), .gap,
        t("4. Calf raises - 3 sets of 15", 24), t("5. Hamstring stretch - hold 30 seconds", 24), .gap,
        t("Page 2 of 2", 20),
    ]], expected: ["area": "Medical", "vendor": "Willow Creek Physical Therapy"]),
    "handwritten_note": Doc(pages: [[
        t("badges to finish -", 30), .gap, t("first aid - need requirement 4", 26), t("camping - 3 more nights", 26),
        t("cooking - plan menu", 26), .gap, t("ask about summer camp sign up", 26),
    ]], expected: [:]),

    "eob": Doc(pages: [[
        t("CEDAR HEALTH PLAN", 40), t("EXPLANATION OF BENEFITS - THIS IS NOT A BILL", 24), .gap,
        t("Statement date: March 2, 2026"), t("Member: Pat Example   ID: CHP-0093312", 24), .gap,
        t("Claim: Office visit, Dr. L. Moreno, 02/03/2026", 24),
        row("Amount billed", "$185.00"), row("Plan discount", "$62.00"), row("Plan paid", "$93.00"), row("You may owe", "$30.00"),
    ]], expected: ["document_type": "Explanation of Benefits", "area": "Medical", "vendor": "Cedar Health Plan",
                   "document_date": "2026-03-02"]),
]

// The scans: which documents, in order, and why
let cases: [(id: String, docs: [String], why: String)] = [
    ("split-two", ["water_bill", "vet_receipt"], "Two unrelated one-page documents."),
    ("split-three", ["bank_statement", "insurance_renewal", "auto_repair"], "A two-page statement, then two one-page documents."),
    ("split-related-invoice", ["invoice_and_receipt"], "An invoice and the receipt for paying it: one document, not two."),
    ("split-letter-then-eob", ["school_letter", "eob"], "A letter with its enclosed form, then an unrelated EOB."),
    ("split-pile", ["water_bill", "bank_statement", "invoice_and_receipt", "insurance_renewal", "vet_receipt",
                    "school_letter", "auto_repair", "eob"], "Eight documents, eleven pages, scanned as one pile."),
    ("split-single-statement", ["bank_statement"], "One two-page statement: must not be split."),
    ("split-service-with-checklist", ["service_with_checklist", "eob"],
     "A repair invoice and the shop's unlabeled inspection checklist (one document), then an EOB."),
    ("split-service-with-dated-form", ["service_with_dated_form"],
     "A receipt and the shop's inspection form with the visit's date: one document."),
    ("split-note-after-last-page", ["exercise_program", "handwritten_note"],
     "A two-page program ending 'Page 2 of 2', then an unrelated handwritten note: two documents."),
]

/// Writes `images` as a PDF of letter-size pages.
func writePDF(_ images: [CGImage], to url: URL) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let pdf = CGContext(url as CFURL, mediaBox: &box, nil)!
    for image in images {
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: box)
        pdf.endPDFPage()
    }
    pdf.closePDF()
}

let scans = outFolder.appendingPathComponent("scans")
try FileManager.default.createDirectory(at: scans, withIntermediateDirectories: true)
var manifest: [[String: Any]] = []
for (index, c) in cases.enumerated() {
    var images: [CGImage] = [], documents: [[String: Any]] = [], at = 1
    for (n, name) in c.docs.enumerated() {
        let doc = docs[name]!
        images += doc.pages.enumerated().map { page($0.element, tilt: CGFloat(((index * 7 + n * 3 + $0.offset) % 9) - 4) * 0.12) }
        documents.append(["pages": [at, at + doc.pages.count - 1], "expected": doc.expected])
        at += doc.pages.count
    }
    let url = scans.appendingPathComponent("\(c.id).pdf")
    writePDF(images, to: url)
    let sha = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    var entry: [String: Any] = ["id": c.id, "scan": "\(c.id).pdf", "why": c.why, "sha256": sha, "verify": [String]()]
    if documents.count == 1 { entry["expected"] = documents[0]["expected"] }
    else { entry["expected"] = [String: Any](); entry["documents"] = documents }
    manifest.append(entry)
}
let json = try JSONSerialization.data(withJSONObject: ["cases": manifest], options: [.prettyPrinted, .sortedKeys])
try json.write(to: outFolder.appendingPathComponent("expected.json"))
print("\(manifest.count) scans in \(outFolder.path)")
