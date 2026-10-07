import Foundation

/// Assembles the file name from facets, so naming rules live in code rather than the prompt:
///   Date-Vendor[-Person][-Vehicle][-Pet]-Description[-Amount].pdf
/// e.g. 2026-01-14-Summit_Neurology-Jane_Smith-Patient_Statement-120.50.pdf
public struct FilenameBuilder: Sendable {
    public let config: TaxonomyConfig

    public init(_ config: TaxonomyConfig) { self.config = config }

    // Accepts yyyy, yyyy-MM, or yyyy-MM-dd — old documents often carry only a year
    nonisolated(unsafe) private static let datePattern = /^\d{4}(-\d{2}(-\d{2})?)?$/

    public func build(_ facets: DocumentFacets) -> String {
        let trimmedDate = facets.documentDate.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = trimmedDate.wholeMatch(of: Self.datePattern) != nil ? trimmedDate : "Undated"

        var segments = [date]
        add(&segments, VendorName.normalize(Self.clean(facets.vendor)))
        add(&segments, Self.clean(facets.person))
        add(&segments, Self.clean(facets.vehicle))
        add(&segments, Self.clean(facets.pet))
        add(&segments, Self.clean(facets.description))

        if let amount = facets.amount, config.includeAmountFor.contains(where: { $0.matches(facets) }) {
            segments.append(TextRules.amount(amount))
        }

        // Date alone is not a usable name
        if segments.count == 1 { segments.append("Document") }

        return segments.joined(separator: "-") + ".pdf"
    }

    /// Skips blanks and repeats — models sometimes put the same name in two fields (a pet in
    /// both person and pet), which shouldn't show up twice in the name.
    private func add(_ segments: inout [String], _ value: String) {
        guard !value.isEmpty, !segments.contains(where: { TextRules.equalsIgnoringCase($0, value) }) else { return }
        segments.append(value)
    }

    /// Spaces become underscores; characters that can't appear in a file name are dropped.
    static func clean(_ value: String) -> String {
        let kept = value.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
            .map { $0 == " " ? "_" : $0 }
            .filter { !["\0", "/", "\\", ":"].contains($0) }
        let collapsed = String(String.UnicodeScalarView(kept)).replacing(/_{2,}/, with: "_")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
    }
}

/// Vendor-name clean-up for file names.
public enum VendorName {
    nonisolated(unsafe) private static let legalSuffix =
        /(?:_(?:Inc|LLC|Corp|Ltd|Co|PLC|LLP|FSB|N\.?A\.?))+$/.ignoresCase()

    // Geographic qualifiers after "of" when the qualifier is a US state or the country
    nonisolated(unsafe) private static let geographicQualifier = try! Regex(
        #"_of_(?:Alabama|Alaska|Arizona|Arkansas|California|Colorado|Connecticut|Delaware|Florida|Georgia|Hawaii|Idaho|Illinois|Indiana|Iowa|Kansas|Kentucky|Louisiana|Maine|Maryland|Massachusetts|Michigan|Minnesota|Mississippi|Missouri|Montana|Nebraska|Nevada|New_Hampshire|New_Jersey|New_Mexico|New_York|North_Carolina|North_Dakota|Ohio|Oklahoma|Oregon|Pennsylvania|Rhode_Island|South_Carolina|South_Dakota|Tennessee|Texas|Utah|Vermont|Virginia|Washington|West_Virginia|Wisconsin|Wyoming|America|North_America|United_States|USA)(?:_\w+)*$"#
    ).ignoresCase()

    // Names that are only a generic word once "of <place>" is gone — "Bank of America" is a name,
    // not the bank "Bank" in America
    private static let genericNames: Set<String> = [
        "bank", "trust", "university", "college", "hospital", "church", "city", "county", "state",
        "commonwealth", "republic", "society", "association", "institute", "museum", "library"
    ]

    /// Strips a leading "The_", geographic qualifiers, and legal suffixes:
    /// "The_Acme_Bank_of_Ohio_N.A." → "Acme_Bank".
    public static func normalize(_ vendor: String) -> String {
        var vendor = vendor
        if vendor.lowercased().hasPrefix("the_") { vendor = String(vendor.dropFirst(4)) }
        // Legal suffixes come off on both sides of the place
        vendor = vendor.replacing(legalSuffix, with: "")
        let withoutPlace = vendor.replacing(geographicQualifier, with: "")
        if !genericNames.contains(withoutPlace.lowercased()) { vendor = withoutPlace }
        return vendor.replacing(legalSuffix, with: "")
    }
}
