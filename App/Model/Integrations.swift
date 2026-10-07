// HomeClerk outside its window: filed documents in Spotlight, and Shortcuts / Siri actions.

import AppIntents
import CoreSpotlight
import HomeClerkKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Spotlight

/// Filed documents in Spotlight, findable by vendor, person, vehicle, pet, tags, and dates — not
/// just the text on the page. The entries stay on this Mac, like the rest of Spotlight's index.
enum Spotlight {
    static let domain = "com.mockclan.homeclerk.filed"

    @MainActor static var enabled: Bool { UserDefaults.standard.object(forKey: DefaultsKey.indexInSpotlight) as? Bool ?? true }

    /// Replaces HomeClerk's entries with these documents; none when indexing is off.
    static func reindex(_ documents: [DocumentIndex.Entry], enabled: Bool) async {
        let index = CSSearchableIndex.default()
        try? await index.deleteSearchableItems(withDomainIdentifiers: [domain])
        guard enabled, !documents.isEmpty else { return }
        try? await index.indexSearchableItems(documents.map(item))
    }

    static func item(_ entry: DocumentIndex.Entry) -> CSSearchableItem {
        let f = entry.facets
        let attributes = CSSearchableItemAttributeSet(contentType: .pdf)
        let title = [FinishingPlan.readable(f.vendor), FinishingPlan.readable(f.description)].filter { !$0.isEmpty }
        attributes.title = title.isEmpty ? (entry.path as NSString).lastPathComponent : title.joined(separator: " — ")
        attributes.contentDescription = entry.summary.isEmpty ? nil : entry.summary
        attributes.keywords = ([f.documentType, f.area, f.vendor, f.person, f.vehicle, f.pet] + f.tags)
            .map(FinishingPlan.readable).filter { !$0.isEmpty }
        attributes.contentURL = URL(fileURLWithPath: entry.path)
        attributes.contentCreationDate = FinishingPlan.localDay(f.documentDate)
        attributes.dueDate = FinishingPlan.localDay(f.dueDate)
        return CSSearchableItem(uniqueIdentifier: entry.path, domainIdentifier: domain, attributeSet: attributes)
    }
}

extension HomeClerkModel {
    /// The filed documents, read from index.jsonl — available to Shortcuts even before watching starts.
    ///
    /// Reading it checks every filed document still exists, so it's kept until the index changes,
    /// HomeClerk renames, moves, or trashes something, or half a minute passes (for files moved in Finder).
    var library: DocumentLibrary {
        let settings = currentSettings ?? SettingsStore.app.load()
        let url = settings.basePath.appendingPathComponent(DocumentIndex.fileName)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = [(attributes?[.modificationDate] as? Date)?.timeIntervalSince1970.description ?? "-",
                     (attributes?[.size] as? NSNumber)?.description ?? "-", String(documentsChanged),
                     String(Int(Date.now.timeIntervalSince1970 / 30)), url.path].joined(separator: "|")
        if let cache = libraryCache, cache.key == stamp { return cache.library }
        let library = DocumentLibrary(documents: DocumentLibrary.load(DocumentIndex(url: url)).documents.filter {
            FileOrganizer.isInside(settings.outboxFolder, settings.basePath)
                && FileOrganizer.isInside(URL(fileURLWithPath: $0.path), settings.outboxFolder)
        })
        libraryCache = (stamp, library)   // not observed, so storing it while a view draws is fine
        return library
    }

    /// Brings Spotlight up to date with what's filed.
    func updateSpotlight() {
        let documents = library.documents
        let enabled = Spotlight.enabled
        Task.detached(priority: .utility) { await Spotlight.reindex(documents, enabled: enabled) }
    }
}

// MARK: - Shortcuts and Siri

struct FindDocumentsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Documents"
    static let description = IntentDescription("Finds filed documents by vendor, person, vehicle, pet, tag, or date.")

    @Parameter(title: "Search", requestValueDialog: "What should HomeClerk look for?")
    var query: String

    static var parameterSummary: some ParameterSummary { Summary("Find documents matching \(\.$query)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> & ProvidesDialog {
        let found = HomeClerkModel.shared.library.find(query)
        let files = found.prefix(25).map { IntentFile(fileURL: URL(fileURLWithPath: $0.path)) }
        let dialog: IntentDialog = switch found.count {
        case 0: "No filed documents match \(query)."
        case 1: "Found 1 document."
        default: "Found \(found.count) documents."
        }
        return .result(value: Array(files), dialog: dialog)
    }
}

struct UpcomingIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Due"
    static let description = IntentDescription("Lists bills due and documents expiring soon.")

    @Parameter(title: "Days ahead", default: 30, inclusiveRange: (1, 365))
    var days: Int

    static var parameterSummary: some ParameterSummary { Summary("What's due in the next \(\.$days) days") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let items = HomeClerkModel.shared.upcoming(days: days, library: HomeClerkModel.shared.library)
        let lines = items.map { "\($0.date): \($0.kind.rawValue) — \($0.title)" }
        let dialog: IntentDialog = items.isEmpty
            ? "Nothing is due or expiring in the next \(days) days."
            : "\(items.count) due or expiring in the next \(days) days. The first is \(lines[0])."
        return .result(value: lines, dialog: dialog)
    }
}

struct ReviewScansIntent: AppIntent {
    static let title: LocalizedStringResource = "Review Scans"
    static let description = IntentDescription("Opens HomeClerk to the scans that need a decision.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        HomeClerkModel.shared.section = .review
        return .result()
    }
}

struct HomeClerkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FindDocumentsIntent(),
                    phrases: ["Find documents in \(.applicationName)", "Search \(.applicationName)"],
                    shortTitle: "Find Documents", systemImageName: "magnifyingglass")
        AppShortcut(intent: UpcomingIntent(),
                    phrases: ["What's due in \(.applicationName)", "What's coming up in \(.applicationName)"],
                    shortTitle: "What's Due", systemImageName: "calendar")
        AppShortcut(intent: ReviewScansIntent(),
                    phrases: ["Review scans in \(.applicationName)", "Open \(.applicationName) review"],
                    shortTitle: "Review Scans", systemImageName: "exclamationmark.bubble")
    }
}
