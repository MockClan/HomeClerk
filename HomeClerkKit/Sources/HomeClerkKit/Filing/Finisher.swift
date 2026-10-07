import CoreText
import EventKit
import Foundation
import os
import PDFKit
import Vision

/// Finishing steps after a document is filed: a searchable text layer, Finder tags, and
/// Reminders. Each is best effort — failures are returned and never undo the filing.
public struct Finisher: Sendable {
    public var makeSearchable: Bool
    public var applyTags: Bool
    public var createReminders: Bool
    public var remindersList: String
    public var expirationLeadDays: Int
    private var issues: FinishingIssues?
    var operations = Operations.live
    struct Operations: Sendable {
        var searchable: @Sendable (URL) throws -> Void
        var tags: @Sendable (URL, [String]) throws -> Void
        var reminders: @Sendable (ReminderReconciliation.Request, String) async throws -> [String]
        static let live = live(originals: nil)
        /// With `originals` (the _originals folder, when scans are kept there), making a just-filed
        /// scan searchable needn't save a second copy of its original bytes beside it.
        static func live(originals: URL?) -> Operations {
            Operations(searchable: { try Searchable.addTextLayer(to: $0, originals: originals) },
                tags: { try ($0 as NSURL).setResourceValue($1, forKey: .tagNamesKey) },
                reminders: { try await Reminders.reconcile($0, inList: $1) })
        }
    }
    private let log = Logger(subsystem: "com.mockclan.homeclerk", category: "finishing")

    public init(makeSearchable: Bool, applyTags: Bool, createReminders: Bool, remindersList: String,
                expirationLeadDays: Int) {
        self.makeSearchable = makeSearchable
        self.applyTags = applyTags
        self.createReminders = createReminders
        self.remindersList = remindersList
        self.expirationLeadDays = expirationLeadDays
    }

    public init(_ settings: HomeClerkSettings) {
        self.init(makeSearchable: settings.makeSearchable, applyTags: settings.applyFinderTags,
                  createReminders: settings.createReminders, remindersList: settings.remindersList,
                  expirationLeadDays: settings.expirationReminderLeadDays)
        issues = FinishingIssues(folder: settings.basePath)
        operations = .live(originals: settings.preserveOriginals ? settings.originalsFolder : nil)
    }

    /// Returns step failures, created reminders, and user-facing warnings. Disabled retry steps
    /// remain pending, rather than being silently cleared.
    @discardableResult
    public func finish(_ pdf: URL, facets: DocumentFacets, today: String, documentID: String? = nil,
                       steps: Set<FinishingStep>? = nil, previousReminders: [ReminderItem] = [],
                       synchronizeReminders: Bool = false) async -> FinishingOutcome {
        var outcome = FinishingOutcome()
        let requested = steps ?? Set(FinishingStep.allCases)
        var attempted = Set<FinishingStep>()
        var previous = previousReminders
        func failed(_ step: FinishingStep, _ error: any Error) {
            outcome.failures.append(.init(step: step, detail: String(describing: error)))
            outcome.warnings.append("Filed \(pdf.lastPathComponent), but \(step.title.lowercased()) needs attention: \(error)")
        }
        // Searchable first: it rewrites the file, which would drop tags applied earlier
        if makeSearchable && requested.contains(.searchable) {
            attempted.insert(.searchable)
            do {
                try Task.checkCancellation()
                try operations.searchable(pdf)
            } catch {
                log.warning("Text layer failed for a filed document: \(error.localizedDescription, privacy: .private)")
                failed(.searchable, error)
            }
        }
        if applyTags && (requested.contains(.tags) || (makeSearchable && requested.contains(.searchable))) {
            attempted.insert(.tags)
            let tags = FinishingPlan.finderTags(facets)
            if !tags.isEmpty {
                do {
                    try Task.checkCancellation()
                    try operations.tags(pdf, tags)
                } catch {
                    log.warning("Tagging failed: \(error.localizedDescription, privacy: .private)")
                    failed(.tags, error)
                }
            }
        }
        if createReminders && requested.contains(.reminders) {
            attempted.insert(.reminders)
            let items = FinishingPlan.reminders(facets, filePath: pdf.path, today: today,
                expirationLeadDays: expirationLeadDays, includingOverduePayments: synchronizeReminders)
            if synchronizeReminders || !items.isEmpty {
                do {
                    try Task.checkCancellation()
                    if let issues, let documentID {
                        previous += try issues.load().first(where: { $0.documentID == documentID })?.reminderPrevious ?? []
                        for item in previous {
                            try FileOrganizer.requireInside(URL(fileURLWithPath: item.filePath), issues.folder.appendingPathComponent("Organized"))
                        }
                    }
                    previous = previous.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
                    if let issues, let documentID {
                        // Keep enough context to retry if the app exits while EventKit is working.
                        try issues.update(documentID: documentID, path: pdf.path, attempted: [.reminders],
                            failures: [.init(step: .reminders, detail: "Reminder synchronization is pending.")],
                            reminderPrevious: previous)
                    }
                    let lapsed = synchronizeReminders ? FinishingPlan.lapsedReminderKinds(facets, today: today) : []
                    outcome.reminders = try await operations.reminders(.init(documentID: documentID, items: items, previous: previous,
                                                                             lapsed: lapsed), remindersList)
                }
                catch {
                    log.warning("Reminders failed: \(error.localizedDescription, privacy: .private)")
                    failed(.reminders, error)
                }
            }
        }
        if let issues, let documentID {
            do { try issues.update(documentID: documentID, path: pdf.path, attempted: attempted,
                                   failures: outcome.failures, reminderPrevious: previous) }
            catch { outcome.warnings.append("Filed \(pdf.lastPathComponent), but finishing repair history couldn't be saved: \(error)") }
        }
        return outcome
    }

    /// The PDF's text layer; empty when it has none.
    public static func text(of pdf: URL) -> String { PDFDocument(url: pdf)?.string ?? "" }
}

/// Adds an invisible OCR text layer to scanned PDFs, so they're searchable in Preview and
/// Spotlight — the same approach scanner apps use for "searchable PDF".
enum Searchable {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Assess pages independently. Keep pages with selectable text and replace only image-only
    /// pages that yield OCR, retaining their geometry, rotation, and annotations.
    static func addTextLayer(to pdf: URL, originals: URL? = nil) throws {
        let originalBytes = try PDFTransformation.readOriginal(pdf)
        guard let document = PDFDocument(data: originalBytes), !document.isLocked, document.pageCount > 0,
              let provider = CGDataProvider(data: originalBytes as CFData),
              let source = CGPDFDocument(provider), source.numberOfPages == document.pageCount
        else { throw Failure(description: "not a readable PDF") }
        var changed = false
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let original = document.page(at: index), let page = source.page(at: index + 1)
            else { throw Failure(description: "can't read every page") }
            // Even short text, such as a date or page number, remains selectable without a second
            // text layer. Partial text/image content on the same page needs a separate coverage pass.
            if !(original.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let box = page.getBoxRect(.mediaBox)
            guard box.origin == .zero else {
                throw Failure(description: "searchable conversion cannot safely retain this page's nonzero origin")
            }
            guard let image = render(page, box: box, dpi: 300)
            else { throw Failure(description: "can't render a page for searchable text") }
            let lines = try recognizeLines(in: image)
            guard !lines.isEmpty else { continue }
            let data = NSMutableData()
            guard let consumer = CGDataConsumer(data: data),
                  let context = CGContext(consumer: consumer, mediaBox: nil, nil)
            else { throw Failure(description: "can't create the output page") }
            var mediaBox = box
            context.beginPage(mediaBox: &mediaBox)
            context.drawPDFPage(page)
            for (string, rect) in lines {
                drawInvisible(string, in: CGRect(x: box.minX + rect.minX * box.width, y: box.minY + rect.minY * box.height,
                                                 width: rect.width * box.width, height: rect.height * box.height),
                              context: context)
            }
            context.endPage()
            context.closePDF()
            guard let generated = PDFDocument(data: data as Data), let replacement = generated.page(at: 0),
                  !(replacement.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw Failure(description: "can't verify the searchable page") }
            for kind in [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
                replacement.setBounds(original.bounds(for: kind), for: kind)
            }
            replacement.rotation = original.rotation
            for annotation in original.annotations { replacement.addAnnotation(annotation) }
            document.removePage(at: index)
            document.insert(replacement, at: index)
            changed = true
        }
        guard changed else { return }
        try PDFTransformation.requireNoForms(source, document: document)
        try Task.checkCancellation()
        let temp = pdf.deletingLastPathComponent().appendingPathComponent(".homeclerk_searchable_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let output = document.dataRepresentation() else { throw Failure(description: "can't create the output PDF") }
        try PrivateFile.write(output, to: temp)
        guard let verified = PDFDocument(url: temp), verified.pageCount == document.pageCount
        else { throw Failure(description: "can't verify the output PDF") }
        for index in 0..<document.pageCount {
            guard let expected = document.page(at: index), let actual = verified.page(at: index) else {
                throw Failure(description: "searchable output lost a page")
            }
            guard expected.string == actual.string, expected.rotation == actual.rotation,
                  expected.bounds(for: .mediaBox) == actual.bounds(for: .mediaBox),
                  expected.bounds(for: .cropBox) == actual.bounds(for: .cropBox),
                  expected.annotations.count == actual.annotations.count
            else { throw Failure(description: "searchable output did not retain every page's text and geometry") }
        }
        try Task.checkCancellation()
        try PDFTransformation.replace(pdf, with: temp, original: originalBytes, operation: "searchable conversion",
                                      alreadyKeptIn: originals)
    }

    static func render(_ page: CGPDFPage, box: CGRect, dpi: CGFloat) -> CGImage? {
        let scale = dpi / 72
        guard box.width.isFinite, box.height.isFinite, box.minX.isFinite, box.minY.isFinite,
              box.width > 0, box.height > 0, dpi.isFinite, dpi > 0,
              box.width * scale <= 10_000, box.height * scale <= 10_000,
              box.width * scale * box.height * scale <= 40_000_000 else { return nil }
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// Recognized lines with bounding boxes normalized to 0–1, origin bottom-left (PDF space).
    static func recognizeLines(in image: CGImage) throws -> [(String, CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Correction mangles codes, drug names, and numbers
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
        }
    }

    /// Draws text invisibly, stretched to cover the recognized line's box so selection highlights
    /// line up with the words on the page.
    static func drawInvisible(_ string: String, in rect: CGRect, context: CGContext) {
        guard rect.width > 1, rect.height > 1 else { return }
        let font = CTFontCreateWithName("Helvetica" as CFString, rect.height, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: [.init(kCTFontAttributeName as String): font]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        guard width > 0 else { return }
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        context.textMatrix = .identity
        context.translateBy(x: rect.minX, y: rect.minY + rect.height * 0.2)
        context.scaleBy(x: rect.width / CGFloat(width), y: 1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// Creates reminders in a Reminders list, skipping ones that already exist for the same
/// document, due date, and title. macOS asks for permission on behalf of HomeClerk.app.
public enum Reminders {
    struct Failure: Error, LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func reconcile(_ request: ReminderReconciliation.Request, inList name: String) async throws -> [String] {
        guard request.documentID != nil else { return try await create(request.items, inList: name) }
        try Task.checkCancellation()
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else {
            throw Failure("Reminders access denied — allow it in System Settings → Privacy & Security → Reminders")
        }
        // An empty desired plan still removes managed reminders in an existing list; it needn't create a list.
        let calendar: EKCalendar
        if let found = store.calendars(for: .reminder).first(where: { $0.title == name }) { calendar = found }
        else if request.items.isEmpty { return [] }
        else { calendar = try list(named: name, in: store) }
        let predicate = store.predicateForReminders(in: [calendar])
        let snapshots: [ReminderReconciliation.Existing] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map { reminder in
                    let c = reminder.dueDateComponents
                    let due = c.flatMap { c -> String? in
                        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
                        return String(format: "%04d-%02d-%02d", y, m, d)
                    } ?? ""
                    return .init(id: reminder.calendarItemIdentifier, title: reminder.title ?? "", due: due,
                        notes: reminder.notes ?? "", path: reminder.url?.path ?? "", completed: reminder.isCompleted)
                })
            }
        }
        let plan = try ReminderReconciliation.plan(request, existing: snapshots)
        try Task.checkCancellation()
        do {
            for id in plan.removes {
                guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
                    throw Failure("A reminder changed during synchronization. Retry to reload it.")
                }
                try store.remove(reminder, commit: false)
            }
            for change in plan.saves {
                let reminder: EKReminder
                if let id = change.existingID {
                    guard let existing = store.calendarItem(withIdentifier: id) as? EKReminder else {
                        throw Failure("A reminder changed during synchronization. Retry to reload it.")
                    }
                    reminder = existing
                } else { reminder = EKReminder(eventStore: store); reminder.calendar = calendar }
                reminder.title = change.item.title
                reminder.notes = change.notes
                reminder.url = URL(fileURLWithPath: change.item.filePath)
                guard let due = FinishingPlan.day(change.item.due) else { throw Failure("Invalid reminder due date") }
                let c = FinishingPlan.calendar.dateComponents([.year, .month, .day], from: due)
                reminder.dueDateComponents = c
                // A rename alone preserves user alarms. A changed date gets the app's morning alarm.
                if snapshots.first(where: { $0.id == change.existingID })?.due != change.item.due {
                    reminder.alarms = []
                    if let local = Calendar.current.date(from: c),
                       let nineAM = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: local) {
                        reminder.addAlarm(EKAlarm(absoluteDate: nineAM))
                    }
                }
                try store.save(reminder, commit: false)
            }
            if !plan.saves.isEmpty || !plan.removes.isEmpty { try store.commit() }
        } catch { store.reset(); throw error }
        return plan.saves.map { "\($0.item.due) \($0.item.title)" }
    }

    /// Returns "yyyy-MM-dd title" for each reminder created.
    public static func create(_ items: [ReminderItem], inList name: String) async throws -> [String] {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else {
            throw Failure("Reminders access denied — allow it in System Settings → Privacy & Security → Reminders")
        }
        let calendar = try list(named: name, in: store)
        var existing = await incompleteReminders(in: calendar, store: store)

        var created: [String] = []
        for item in items {
            let key = "\(item.due) \(item.title)"
            let identity = key + "\n" + item.filePath
            guard !existing.contains(identity), let due = FinishingPlan.day(item.due) else { continue }
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = calendar
            reminder.title = item.title
            reminder.notes = item.notes
            reminder.url = URL(fileURLWithPath: item.filePath)
            var components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: due)
            components = DateComponents(year: components.year, month: components.month, day: components.day)
            reminder.dueDateComponents = components
            // Morning-of alert so it shows up in Notification Center
            if let local = Calendar.current.date(from: components),
               let nineAM = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: local) {
                reminder.addAlarm(EKAlarm(absoluteDate: nineAM))
            }
            try store.save(reminder, commit: false)
            existing.insert(identity)
            created.append(key)
        }
        try store.commit()
        return created
    }

    /// Ticks off — or, with `done` false, reopens — the "Pay …" reminder made for a bill: the one
    /// linking to its document. Titles and dates alone can belong to another household bill. Returns
    /// how many changed; none when there's no such list or reminder.
    @discardableResult
    public static func setPaymentDone(_ done: Bool, bill facets: DocumentFacets, path: String,
                                      documentID: String? = nil, inList name: String)
        async throws -> Int {
        try Task.checkCancellation()
        guard FinishingPlan.paymentReminderTitle(facets) != nil else { return 0 }
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else {
            throw Failure("Reminders access denied — allow it in System Settings → Privacy & Security → Reminders")
        }
        guard let calendar = store.calendars(for: .reminder).first(where: { $0.title == name }) else { return 0 }
        let predicate = done
            ? store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [calendar])
            : store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: [calendar])
        let identifiers: [String] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let legacy = FinishingPlan.reminders(facets, filePath: path, today: "0001-01-01", expirationLeadDays: 30)
                    .first { $0.kind == .payment }
                let matching = (reminders ?? []).filter { reminder in
                    if let documentID, reminder.notes?.components(separatedBy: "\n").last ==
                        ReminderReconciliation.marker(documentID, .payment) { return true }
                    guard let legacy, let c = reminder.dueDateComponents,
                          let y = c.year, let m = c.month, let d = c.day else { return false }
                    return reminder.url?.path == legacy.filePath && reminder.title == legacy.title &&
                        reminder.notes == legacy.notes && String(format: "%04d-%02d-%02d", y, m, d) == legacy.due
                }
                continuation.resume(returning: matching.map(\.calendarItemIdentifier))
            }
        }
        try Task.checkCancellation()
        var changed = 0
        do {
            for identifier in identifiers {
                try Task.checkCancellation()
                guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else { continue }
                reminder.isCompleted = done
                try store.save(reminder, commit: false)
                changed += 1
            }
            try Task.checkCancellation()
            if changed > 0 { try store.commit() }
        } catch {
            store.reset()
            throw error
        }
        return changed
    }

    /// After the HomeClerk folder moves, points reminders that open a document in it at its new
    /// place. Only links into the old folder change; everything else about a reminder stays.
    /// Returns how many were updated.
    @discardableResult
    public static func relink(from source: URL, to destination: URL, inList name: String) async throws -> Int {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else {
            throw Failure("Reminders access denied — allow it in System Settings → Privacy & Security → Reminders")
        }
        guard let calendar = store.calendars(for: .reminder).first(where: { $0.title == name }) else { return 0 }
        let links: [(id: String, path: String)] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: store.predicateForReminders(in: [calendar])) { reminders in
                continuation.resume(returning: (reminders ?? []).compactMap { reminder in
                    guard let url = reminder.url, url.isFileURL else { return nil }
                    return (reminder.calendarItemIdentifier, url.path)
                })
            }
        }
        var changed = 0
        for link in links {
            guard let moved = FolderMove.rebased(link.path, from: source, to: destination),
                  let reminder = store.calendarItem(withIdentifier: link.id) as? EKReminder else { continue }
            reminder.url = URL(fileURLWithPath: moved)
            try store.save(reminder, commit: false)
            changed += 1
        }
        if changed > 0 { try store.commit() }
        return changed
    }

    static func list(named name: String, in store: EKEventStore) throws -> EKCalendar {
        if let found = store.calendars(for: .reminder).first(where: { $0.title == name }) { return found }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = name
        guard let source = store.defaultCalendarForNewReminders()?.source else { throw Failure("no Reminders account") }
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return calendar
    }

    /// Due date, title, and linked document for each incomplete reminder.
    static func incompleteReminders(in calendar: EKCalendar, store: EKEventStore) async -> Set<String> {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [calendar])
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let keys = (reminders ?? []).compactMap { r -> String? in
                    guard let c = r.dueDateComponents, let y = c.year, let m = c.month, let d = c.day else { return nil }
                    return String(format: "%04d-%02d-%02d %@", y, m, d, r.title ?? "") + "\n" + (r.url?.path ?? "")
                }
                continuation.resume(returning: Set(keys))
            }
        }
    }
}
