import Foundation
import PDFKit

// MARK: - Search filters

extension DocumentLibrary {
    /// Narrows a search to a person, vehicle, pet, year, or document type. Empty means any.
    public struct Filter: Equatable, Sendable, Codable {
        public var person = ""
        public var vehicle = ""
        public var pet = ""
        public var year = ""
        public var type = ""

        public init(person: String = "", vehicle: String = "", pet: String = "", year: String = "", type: String = "") {
            self.person = person
            self.vehicle = vehicle
            self.pet = pet
            self.year = year
            self.type = type
        }

        public var isEmpty: Bool { self == Filter() }

        public func matches(_ f: DocumentFacets) -> Bool {
            (person.isEmpty || f.person == person) && (vehicle.isEmpty || f.vehicle == vehicle)
                && (pet.isEmpty || f.pet == pet) && (year.isEmpty || f.documentDate.hasPrefix(year))
                && (type.isEmpty || TextRules.equalsIgnoringCase(f.documentType, type))
        }
    }

    /// Documents matching every search word and the filter, newest first. With only a filter,
    /// every document it matches.
    public func find(_ query: String, filter: Filter) -> [DocumentIndex.Entry] {
        let base = query.split(separator: " ").isEmpty
            ? documents.sorted { $0.facets.documentDate > $1.facets.documentDate }
            : find(query)
        return filter.isEmpty && query.split(separator: " ").isEmpty ? [] : base.filter { filter.matches($0.facets) }
    }

    /// The values in use for a filter's pickers: people, vehicles, pets, years, and types.
    public func choices(_ value: (DocumentFacets) -> String) -> [String] {
        Array(Set(documents.map { value($0.facets) }.filter { !$0.isEmpty })).sorted()
    }

    public var years: [String] {
        Array(Set(documents.compactMap { d in
            d.facets.documentDate.count >= 4 ? String(d.facets.documentDate.prefix(4)) : nil
        })).sorted(by: >)
    }
}

// MARK: - Keep periods

/// A filed document past the time it's worth keeping, by the taxonomy's retention rules.
public struct ExpiredDocument: Equatable, Sendable, Identifiable {
    public var id: String { entry.path }
    public var entry: DocumentIndex.Entry
    /// yyyy-MM-dd
    public var keepUntil: String
    public var reason: String
}

public enum Retention {
    /// The rule for a document: the first that matches.
    public static func rule(for facets: DocumentFacets, in rules: [RetentionRule]) -> RetentionRule? {
        rules.first { $0.condition.matches(facets) }
    }

    /// Documents whose keep period ended by `today` (yyyy-MM-dd), oldest first, leaving out those
    /// you chose to keep anyway. Undated documents are never listed.
    public static func expired(_ documents: [DocumentIndex.Entry], rules: [RetentionRule], today: String,
                               keeping: Set<String> = []) -> [ExpiredDocument] {
        documents.compactMap { entry in
            guard !keeping.contains(entry.path), let rule = rule(for: entry.facets, in: rules), let years = rule.keepYears,
                  FinishingPlan.day(entry.facets.documentDate) != nil else { return nil }
            let until = addYears(entry.facets.documentDate, years)
            return until <= today ? ExpiredDocument(entry: entry, keepUntil: until, reason: rule.reason) : nil
        }.sorted { $0.keepUntil < $1.keepUntil }
    }

    /// Rules that keep documents like these indefinitely, one per area and type, in the order given.
    public static func keepRules(like documents: [DocumentFacets]) -> [RetentionRule] {
        var seen = Set<String>()
        return documents.compactMap { f in
            guard seen.insert(TextRules.key(f.area) + "|" + TextRules.key(f.documentType)).inserted else { return nil }
            let condition = FacetCondition(area: f.area.isEmpty ? nil : f.area,
                                           types: f.documentType.isEmpty ? nil : [f.documentType])
            return RetentionRule(condition: condition, keepYears: nil, reason: "You chose to keep these.")
        }
    }

    /// "2025-02-28" + 1 → "2026-02-28" (Feb 29 becomes Feb 28).
    static func addYears(_ day: String, _ years: Int) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        let year = parts[0] + years, month = parts[1]
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let dayOfMonth = month == 2 && parts[2] == 29 && !leap ? 28 : parts[2]
        return String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
    }
}

// MARK: - Tax-year export

public enum TaxPacket {
    /// Tax documents for a tax year: those dated in the year, plus tax forms and returns dated
    /// January through April of the next (W-2s and 1099s for a year arrive early the next one).
    public static func documents(_ documents: [DocumentIndex.Entry], year: Int, taxonomy: TaxonomyConfig) -> [DocumentIndex.Entry] {
        let conditions = [FacetCondition(area: "Taxes")] + taxonomy.taxDocuments
        let thisYear = String(format: "%04d", year), next = String(format: "%04d", year + 1)
        return documents.filter { d in
            let f = d.facets
            guard conditions.contains(where: { $0.matches(f) }) else { return false }
            if f.documentDate.hasPrefix(thisYear) { return true }
            let earlyNext = f.documentDate.hasPrefix(next) && (Int(f.documentDate.dropFirst(5).prefix(2)) ?? 13) <= 4
            let isForm = ["Tax Form", "Tax Return"].contains { TextRules.equalsIgnoringCase($0, f.documentType) }
            return earlyNext && isForm
        }.sorted { ($0.facets.documentDate, $0.path) < ($1.facets.documentDate, $1.path) }
    }

    /// Copies the documents into "<year> Tax Documents" inside `folder`, grouped as they're filed,
    /// with an Index.csv and, if asked, every document combined into one PDF. Returns the new folder.
    @discardableResult
    public static func export(_ documents: [DocumentIndex.Entry], year: Int, to folder: URL, combinedPDF: Bool) throws -> URL {
        let out = FileOrganizer.unique(folder.appendingPathComponent("\(year) Tax Documents"))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var csv = "Date,Type,Vendor,Description,Amount,Person,File\n"
        let combined = PDFDocument()
        for d in documents {
            let source = URL(fileURLWithPath: d.path)
            let group = source.deletingLastPathComponent().lastPathComponent
            let destinationFolder = out.appendingPathComponent(FileOrganizer.sanitizeFolder(group))
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            let copy = FileOrganizer.unique(destinationFolder.appendingPathComponent(source.lastPathComponent))
            try FileManager.default.copyItem(at: source, to: copy)
            let f = d.facets
            csv += [f.documentDate, FinishingPlan.readable(f.documentType), FinishingPlan.readable(f.vendor),
                    FinishingPlan.readable(f.description), f.amount.map { TextRules.amount($0) } ?? "",
                    FinishingPlan.readable(f.person), "\(group)/\(copy.lastPathComponent)"].map(csvField).joined(separator: ",") + "\n"
            if combinedPDF, let pdf = PDFDocument(url: source) {
                for i in 0..<pdf.pageCount { if let page = pdf.page(at: i) { combined.insert(page, at: combined.pageCount) } }
            }
        }
        try csv.write(to: out.appendingPathComponent("Index.csv"), atomically: true, encoding: .utf8)
        if combinedPDF, combined.pageCount > 0 {
            combined.write(to: out.appendingPathComponent("All \(year) tax documents.pdf"))
        }
        return out
    }

    /// A CSV cell. Text read from a document that starts like a formula (=, +, -, @) gets a leading
    /// apostrophe, so a spreadsheet shows it rather than running it; plain numbers are left alone.
    static func csvField(_ value: String) -> String {
        var value = value
        if let first = value.first, "=+-@".contains(first), Double(value) == nil { value = "'" + value }
        return value.contains(where: { ",\"\n".contains($0) }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
    }
}

// MARK: - Duplicates

/// A scan set aside in _duplicates as already filed.
public struct DuplicateItem: Equatable, Sendable, Identifiable {
    public var id: String { url.path }
    public var url: URL
    /// The filed document it repeats, inside Organized; nil if it's no longer there.
    public var original: URL?
    public var originalLabel: String
    public var why: String
}

extension ReviewActions {
    /// Scans in _duplicates, newest first, each with the filed document it repeats.
    public func duplicateItems() -> [DuplicateItem] {
        let files = (try? FileManager.default.contentsOfDirectory(at: settings.duplicatesFolder,
                                                                  includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "pdf" && FileOrganizer.isInside($0, settings.duplicatesFolder) }
            .sorted { (Self.modified($0) ?? .distantPast) > (Self.modified($1) ?? .distantPast) }
            .map { scan in
                let reason = (try? String(contentsOf: ReviewProposal.reasonURL(for: scan), encoding: .utf8)) ?? ""
                var label = "", why = ""
                for line in reason.split(separator: "\n") {
                    if line.hasPrefix("Duplicate of: ") { label = String(line.dropFirst("Duplicate of: ".count)) }
                    if line.hasPrefix("Why: ") { why = String(line.dropFirst("Why: ".count)) }
                }
                let original = label.isEmpty ? nil : settings.outboxFolder.appendingPathComponent(label)
                let exists = original.map { FileOrganizer.isInside($0, settings.outboxFolder)
                    && FileManager.default.fileExists(atPath: $0.path) } ?? false
                return DuplicateItem(url: scan, original: exists ? original : nil, originalLabel: label, why: why)
            }
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Not a duplicate after all: moves it to Review (with the model's proposal, if it had one) to
    /// be filed as its own document.
    @discardableResult
    public func notADuplicate(_ item: DuplicateItem) throws -> URL {
        try requireManaged(item.url, in: settings.duplicatesFolder)
        try requireManaged(settings.reviewFolder, in: settings.reviewFolder)
        try FileManager.default.createDirectory(at: settings.reviewFolder, withIntermediateDirectories: true)
        let destination = FileOrganizer.unique(settings.reviewFolder.appendingPathComponent(item.url.lastPathComponent))
        try FileManager.default.moveItem(at: item.url, to: destination)
        if let proposal = ReviewProposal.load(for: item.url) { try ReviewProposal.save(proposal, for: destination) }
        try "You said this isn't a duplicate of \(item.originalLabel).".write(to: ReviewProposal.reasonURL(for: destination),
                                                                             atomically: true, encoding: .utf8)
        ReviewProposal.deleteSidecars(for: item.url)
        return destination
    }

    /// Removes a duplicate's notes once the scan itself has gone to the Trash.
    public func forgetDuplicate(_ item: DuplicateItem) {
        guard (try? requireManaged(item.url, in: settings.duplicatesFolder)) != nil else { return }
        ReviewProposal.deleteSidecars(for: item.url)
    }

    // MARK: Splitting a scan by hand

    /// Files a scan as several documents, each its own page range and details. The scan's bytes are
    /// returned in the result so undo can put it back as it was.
    public func fileSplit(_ scan: URL, documents: [FacetDocument], analysis: FacetAnalysis?) async throws -> SplitFiling {
        let operation = try DocumentOperations.acquire([scan])
        defer { operation.release() }
        try requireManaged(scan, in: settings.reviewFolder)
        let pageCount = PDFDocument(url: scan)?.pageCount ?? 0
        if let problem = FacetDocument.pageCoverageProblem(documents, pageCount: pageCount) {
            throw SplitError(message: problem)
        }
        let original = try Data(contentsOf: scan)
        let reason = try? String(contentsOf: ReviewProposal.reasonURL(for: scan), encoding: .utf8)
        var reserved = Set<String>()
        let outputs = try documents.map { d in
            let (folder, name) = destination(d.facets)
            let to = try organizer.destination(folder: folder, filename: name, reserved: reserved)
            reserved.insert(to.path)
            let entry = DocumentIndex.Entry(path: to.path, source: "review:\(scan.lastPathComponent)",
                pages: [d.firstPage, d.lastPage], model: analysis?.model ?? "", confidence: d.confidence,
                summary: analysis?.summary ?? "", facets: d.facets)
            return FilingTransaction.Output(destination: to, entry: entry, pages: d.firstPage...d.lastPage)
        }
        let destinationOperation = try DocumentOperations.acquire(outputs.map(\.destination))
        defer { destinationOperation.release() }
        let result = try FilingTransaction(settings: settings, index: index).execute(source: scan,
            outputs: outputs, deleteSidecars: true)
        result.warnings.forEach(warnings)
        var filings: [Filing] = []
        for (output, document) in zip(outputs, documents) {
            let outcome = await finisher.finish(output.destination, facets: document.facets, today: DocumentProcessor.localToday(), documentID: output.entry.documentID)
            outcome.warnings.forEach(warnings)
            let duplicateLabel = label(output.destination)
            let hash = (try? Data(contentsOf: output.destination)).map(BackfillApplier.sha256) ?? ""
            duplicates.register(ocrText: Finisher.text(of: output.destination), sha256: hash,
                facets: document.facets, label: duplicateLabel)
            filings.append(Filing(scan: scan, destination: output.destination, duplicateLabel: duplicateLabel))
        }
        result.recordOriginalFiling(settings: settings).forEach(warnings)
        return SplitFiling(scan: scan, original: original, reason: reason, proposal: analysis, parts: filings)
    }

    public struct SplitFiling: Sendable {
        public var scan: URL
        var original: Data
        var reason: String?
        var proposal: FacetAnalysis?
        public var parts: [Filing]
    }

    public struct SplitError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Takes the filed parts away and puts the scan back in Review as it was.
    public func undo(_ split: SplitFiling) throws {
        let operation = try DocumentOperations.acquire([split.scan] + split.parts.map(\.destination))
        defer { operation.release() }
        try requireManaged(split.scan, in: settings.reviewFolder)
        for part in split.parts { try requireManaged(part.destination, in: settings.outboxFolder) }
        let back = FileOrganizer.unique(split.scan)
        try PrivateFile.write(split.original, to: back)
        if let reason = split.reason { try reason.write(to: ReviewProposal.reasonURL(for: back), atomically: true, encoding: .utf8) }
        if let proposal = split.proposal { try ReviewProposal.save(proposal, for: back) }
        for part in split.parts {
            try FileManager.default.removeItem(at: part.destination)
            if let label = part.duplicateLabel { duplicates.unregister(label: label) }
        }
    }
}

// MARK: - Sending a filed document back

extension ReviewActions {
    /// A filed document moved back to Review, so undo can put it back.
    public struct Returned: Sendable {
        public var entry: DocumentIndex.Entry
        public var scan: URL
    }

    /// Takes a filed document out of Organized and into Review, with what HomeClerk read as its
    /// proposal, to be filed again — say, when it went to the wrong place.
    @discardableResult
    public func returnToReview(_ entry: DocumentIndex.Entry) throws -> Returned {
        let operation = try DocumentOperations.acquire([URL(fileURLWithPath: entry.path)])
        defer { operation.release() }
        let filed = URL(fileURLWithPath: entry.path)
        try requireManaged(filed, in: settings.outboxFolder)
        try requireManaged(settings.reviewFolder, in: settings.reviewFolder)
        guard FileOrganizer.isInside(filed, settings.outboxFolder) else { throw FileOrganizer.OutsideOrganized() }
        try PaidMarks(url: settings.basePath.appendingPathComponent(PaidMarks.fileName)).migrateLegacyMark(for: entry)
        try FileManager.default.createDirectory(at: settings.reviewFolder, withIntermediateDirectories: true)
        let scan = FileOrganizer.unique(settings.reviewFolder.appendingPathComponent(filed.lastPathComponent))
        try FileManager.default.moveItem(at: filed, to: scan)
        let pages = max(PDFDocument(url: scan)?.pageCount ?? 1, 1)
        var proposal = FacetAnalysis(documents: [FacetDocument(firstPage: 1, lastPage: pages, facets: entry.facets,
                                                               confidence: entry.confidence)],
                                     summary: entry.summary)
        proposal.model = entry.model
        proposal.documentID = entry.documentID
        try ReviewProposal.save(proposal, for: scan)
        try "You sent this back from \(filed.deletingLastPathComponent().lastPathComponent) to file again."
            .write(to: ReviewProposal.reasonURL(for: scan), atomically: true, encoding: .utf8)
        duplicates.unregister(label: label(filed))
        return Returned(entry: entry, scan: scan)
    }

    /// Puts a document sent back to Review where it was filed.
    public func undo(_ returned: Returned) throws {
        let operation = try DocumentOperations.acquire([returned.scan, URL(fileURLWithPath: returned.entry.path)])
        defer { operation.release() }
        let filed = URL(fileURLWithPath: returned.entry.path)
        try requireManaged(filed, in: settings.outboxFolder)
        try requireManaged(returned.scan, in: settings.reviewFolder)
        try FileManager.default.createDirectory(at: filed.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: filed.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: filed.path])
        }
        try FileManager.default.moveItem(at: returned.scan, to: filed)
        ReviewProposal.deleteSidecars(for: returned.scan)
        let sha256 = (try? Data(contentsOf: filed)).map { BackfillApplier.sha256($0) } ?? ""
        duplicates.register(ocrText: Finisher.text(of: filed), sha256: sha256, facets: returned.entry.facets, label: label(filed))
    }
}

// MARK: - Trashed filed documents

extension ReviewActions {
    /// Forgets a filed document's fingerprint once it's gone (to the Trash, say), so scanning it
    /// again isn't flagged as a duplicate of something you threw away.
    public func forgetFiled(_ url: URL) {
        guard FileOrganizer.isInside(url, settings.outboxFolder) else { return }
        duplicates.unregister(label: label(url))
        // Its Library record goes too, or Library Health would list it as missing
        markRecord(url, removed: true)
    }

    /// Remembers it again when it comes back (⌘Z after moving it to the Trash).
    public func rememberFiled(_ url: URL, facets: DocumentFacets?) {
        guard FileOrganizer.isInside(url, settings.outboxFolder) else { return }
        markRecord(url, removed: false)
        guard let data = try? Data(contentsOf: url) else { return }
        duplicates.register(ocrText: Finisher.text(of: url), sha256: BackfillApplier.sha256(data), facets: facets,
                            label: label(url))
    }

    /// Appends the path's current record with `removed` set, when it differs.
    private func markRecord(_ url: URL, removed: Bool) {
        let path = url.standardizedFileURL.path
        guard var entry = index.load().last(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == path }),
              entry.removed != removed else { return }
        entry.removed = removed
        do { try index.append(entry) } catch { warnings("Couldn't update the Library record for \(url.lastPathComponent): \(error)") }
    }
}

// MARK: - Documents that need details

extension DocumentLibrary {
    /// Filed documents with too little to go on — in the taxonomy's catch-all folder (where a
    /// document with no details lands), or with neither a vendor nor a description, so its file
    /// name says almost nothing. Newest first, leaving out ones you chose to leave as they are.
    public func needingDetails(taxonomy: TaxonomyConfig, leaving: Set<String> = []) -> [DocumentIndex.Entry] {
        let catchAll = FilingRouter(taxonomy).folder(for: DocumentFacets())
        return documents.filter { d in
            guard !leaving.contains(d.path) else { return false }
            let folder = ((d.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return folder == catchAll || (d.facets.vendor.isEmpty && d.facets.description.isEmpty)
        }
        .sorted { $0.filedAt > $1.filedAt }
    }
}

// MARK: - Combining scans

extension ReviewActions {
    /// Scans in Review joined into one, and where the separate scans went, so it can be undone.
    public struct Combination: Sendable {
        public var scan: URL
        /// (the file in the Trash, where it was)
        var trashed: [(from: URL, to: URL)]
    }

    /// Joins scans in Review into one — pages in the order given — named after the first, for a
    /// document a scanner saved in pieces. The separate scans (and their notes) go to the Trash.
    @discardableResult
    public func combine(_ scans: [URL]) throws -> Combination {
        let operation = try DocumentOperations.acquire(scans)
        defer { operation.release() }
        guard scans.count > 1 else { throw SplitError(message: "Choose at least two scans to combine") }
        for scan in scans { try requireManaged(scan, in: settings.reviewFolder) }
        let combined = PDFDocument()
        for scan in scans {
            guard let pdf = PDFDocument(url: scan) else { throw SplitError(message: "Can't read \(scan.lastPathComponent)") }
            for i in 0..<pdf.pageCount {
                if let page = pdf.page(at: i)?.copy() as? PDFPage { combined.insert(page, at: combined.pageCount) }
            }
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("homeclerk_combined_\(UUID().uuidString).pdf")
        guard combined.write(to: temp) else { throw SplitError(message: "Couldn't write the combined scan") }

        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = FileOrganizer.unique(scans[0])
        var trashed: [(from: URL, to: URL)] = []
        try FileManager.default.moveItem(at: temp, to: destination)
        do {
            try "Combined from \(scans.count) scans: \(scans.map(\.lastPathComponent).joined(separator: ", ")). Read it again, or fill in its details."
                .write(to: ReviewProposal.reasonURL(for: destination), atomically: true, encoding: .utf8)
            for scan in scans {
                for file in [scan, ReviewProposal.reasonURL(for: scan), ReviewProposal.proposalURL(for: scan)]
                where FileManager.default.fileExists(atPath: file.path) {
                    var inTrash: NSURL?
                    try FileManager.default.trashItem(at: file, resultingItemURL: &inTrash)
                    if let inTrash { trashed.append((inTrash as URL, file)) }
                }
            }
        } catch {
            // Keep the complete combined copy if any original cannot be restored.
            do {
                for item in trashed.reversed() { try FileManager.default.moveItem(at: item.from, to: item.to) }
                try FileManager.default.removeItem(at: destination)
                ReviewProposal.deleteSidecars(for: destination)
            } catch { throw SplitError(message: "Combining failed; complete combined copy preserved at \(destination.path)") }
            throw error
        }
        return Combination(scan: destination, trashed: trashed)
    }

    /// Takes the combined scan away and brings the separate ones back from the Trash.
    public func undo(_ combination: Combination) throws {
        let operation = try DocumentOperations.acquire([combination.scan] + combination.trashed.flatMap { [$0.from, $0.to] })
        defer { operation.release() }
        try requireManaged(combination.scan, in: settings.reviewFolder)
        for item in combination.trashed { try requireManaged(item.to, in: settings.reviewFolder) }
        for item in combination.trashed { try FileManager.default.moveItem(at: item.from, to: item.to) }
        try FileManager.default.removeItem(at: combination.scan)
        ReviewProposal.deleteSidecars(for: combination.scan)
    }
}

// MARK: - Originals worth clearing

/// A scan's copy in _originals that's no longer needed: old, and filed fine.
public struct ClearableOriginal: Equatable, Sendable, Identifiable {
    public var id: String { url.path }
    public var url: URL
    public var size: Int64
    public var copied: Date
}
