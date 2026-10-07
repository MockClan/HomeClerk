import Foundation

/// Builds the prompts for facet extraction from taxonomy.json and the household profile. Filing
/// and naming rules live in code (`FilingRouter`, `FilenameBuilder`), so the prompt only has to
/// describe how to read a document.
public enum FacetPrompt {
    public static func buildSystem(_ taxonomy: TaxonomyConfig, _ profile: HouseholdProfile) -> String {
        var out = instructions + "\n"
        func line(_ text: String) { out += text + "\n" }

        line("Document types:")
        for t in taxonomy.documentTypes { line("- \(t.name): \(t.description)") }

        line("\nAreas:")
        for a in taxonomy.areas { line("- \(a.name): \(a.description)") }

        line("\nSuggested tags:")
        for (tag, description) in taxonomy.suggestedTags { line("- \(tag): \(description)") }

        let household = profile.promptText()
        if !household.isEmpty {
            line("\n# Household")
            line(household)
        }
        return out.trimmingTrailingWhitespace()
    }

    public static func buildUserText(ocrText: String, pageCount: Int) -> String {
        let ocr = ocrText.allSatisfy(\.isWhitespace) ? "(OCR found no text — rely on the page images)" : ocrText
        return """
            This PDF has \(pageCount) page\(pageCount == 1 ? "" : "s").

            OCR text:
            <ocr>
            \(ocr)
            </ocr>
            """
    }

    private static let instructions = """
        You file scanned household documents for the family described below. For each scanned PDF you
        receive the page images and the OCR text Apple Vision extracted from them. Read the page images;
        the OCR text helps with small print, but trust the images where the two disagree.

        Start with a short summary of what the PDF contains and any judgment calls you made (which page
        dates you chose, why pages belong together). Then describe each document with facts. Code decides the folder and filename from those facts, so
        choose values that describe the document itself.

        How to fill each field:
        - document_type and area: choose from the lists below.
        - tags: include every suggested tag that applies. Add a new lowercase-kebab tag only when no
          suggested tag covers something worth grouping by.
        - vendor: who issued the document. When the household lists the vendor, use its canonical name
          exactly. Otherwise use the shortest widely recognized name with underscores for spaces, dropping
          legal suffixes (Inc, LLC, Corp, N.A.), geographic qualifiers ("of Ohio"), and a leading
          "The". For pay stubs and employer notices, the vendor is the employer.
        - description: 2–4 words in Title_Case_With_Underscores naming what the document is
          (Patient_Statement, Prior_Auth_Ozempic, Toll_Bill, Rabies_Vaccination_Certificate). Don't repeat
          the area or type name, the person, or account numbers.
        - document_date: the date printed on the document — statement, service, issue, or transfer date —
          as yyyy-MM-dd, or yyyy when only a year is printed. If the document shows no date, leave it
          empty. Never use the date you are reading it.
        - due_date: payment due date. expires_on: expiration, renewal, or end-of-coverage date. Empty
          when absent.
        - amount: the total due, charged, or paid on bills, receipts, and statements; null when the
          document has no such total. Never an account, invoice, or claim number.
        - person, vehicle, pet: who or what the document is about, using the household's canonical names.
          For medical documents, the person is the patient, not the guarantor. Match vehicles by VIN when
          one is printed. For people outside the household, use their name as First_Last. When the
          document is about a group as a whole — a roster, sign-up sheet, or test or attendance record
          listing several members of a troop, team, class, or other unit — the person is the group
          (Troop_101, Team_Blue), even when a household member appears on it as a member, leader,
          instructor, supervisor, or signer. Leave empty when the document isn't about a specific person,
          group, vehicle, or pet.
        - confidence: how sure you are of document_type, area, and vendor together — 0.9 or above when
          clear, 0.7–0.9 with some ambiguity, below 0.5 when the scan is unreadable.

        A PDF sometimes holds several unrelated documents scanned together — different issuers, dates, or
        document types. Return one entry per document with its first and last page. A single document
        returns one entry covering every page. Multi-page statements, forms with continuation pages, and
        letters with their enclosures are one document.

        Distinctions that come up often:
        - Explanation of Benefits describes a claim already processed (billed, plan paid, you owe; "this
          is not a bill"). Prior Authorization approves or denies a future drug, procedure, or equipment.
          Appeal contests one of those decisions.
        - Area Medical covers care for a person, including the insurer's claim, authorization, and appeal
          letters about that care. Area Insurance covers the policy itself: coverage, premiums, ID cards,
          COBRA continuation.
        - Warranty extensions and recall notices go to the area of the thing they cover (a car's warranty
          is area Vehicle).
        """
}
