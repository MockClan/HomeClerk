import Foundation

/// Documents a reader split apart that belong together.
enum RelatedDocuments {
    /// A bill followed directly by the receipt for paying it — same vendor, same amount — is one
    /// document: the receipt, so the bill doesn't also show as unpaid in Upcoming.
    static func merged(_ analysis: FacetAnalysis) -> FacetAnalysis {
        guard analysis.error == nil, analysis.documents.count > 1 else { return analysis }
        var documents: [FacetDocument] = []
        for document in analysis.documents.sorted(by: { $0.firstPage < $1.firstPage }) {
            if let bill = documents.last, paid(bill, by: document) {
                documents[documents.count - 1] = FacetDocument(firstPage: bill.firstPage, lastPage: document.lastPage,
                                                               facets: document.facets,
                                                               confidence: min(bill.confidence, document.confidence))
            } else {
                documents.append(document)
            }
        }
        var result = analysis
        result.documents = documents
        return result
    }

    static func paid(_ bill: FacetDocument, by receipt: FacetDocument) -> Bool {
        guard receipt.firstPage == bill.lastPage + 1,
              TextRules.equalsIgnoringCase(bill.facets.documentType, "Bill"),
              TextRules.equalsIgnoringCase(receipt.facets.documentType, "Receipt"),
              !bill.facets.vendor.isEmpty, TextRules.key(bill.facets.vendor) == TextRules.key(receipt.facets.vendor),
              let owed = bill.facets.amount, let paid = receipt.facets.amount else { return false }
        return abs(NSDecimalNumber(decimal: owed - paid).doubleValue) < 0.005
    }
}
