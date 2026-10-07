// Getting documents in from anywhere (an iPhone, Mail, Finder's menu), quieter notifications, the
// Monday summary, and Claude's monthly limit.

import AppKit
import HomeClerkKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Documents from an iPhone, Mail, and other apps

extension HomeClerkModel {
    /// Pages from Continuity Camera (File ▸ Import from iPhone): a scanned PDF, or a photo, which
    /// becomes a one-page PDF.
    func importFromDevice(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.pdf.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in HomeClerkModel.shared.addToInbox(data: data, named: Self.scanName()) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let image = NSImage(data: data), let page = PDFPage(image: image) else { return }
                    let pdf = PDFDocument()
                    pdf.insert(page, at: 0)
                    guard let pdfData = pdf.dataRepresentation() else { return }
                    Task { @MainActor in HomeClerkModel.shared.addToInbox(data: pdfData, named: Self.scanName()) }
                }
            }
        }
    }

    /// Drops onto the window: Finder files, and attachments from Mail, Safari, and other apps, which
    /// hand over a PDF to be copied rather than a file.
    func receiveDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in HomeClerkModel.shared.addToInbox([url]) } }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                let name = provider.suggestedName.map { $0.lowercased().hasSuffix(".pdf") ? $0 : $0 + ".pdf" } ?? Self.scanName()
                // The file is only there while this runs, so its bytes are read now
                provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, _ in
                    guard let url, let data = try? Data(contentsOf: url) else { return }
                    Task { @MainActor in HomeClerkModel.shared.addToInbox(data: data, named: name) }
                }
            }
        }
    }

    /// Writes a PDF that arrived as data into a temporary file, then adds it like any other.
    func addToInbox(data: Data, named name: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HomeClerk-\(UUID().uuidString)")
        // A name the inbox would skip (hidden, or not a PDF) or that would make a path, made safe
        var safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while safe.hasPrefix(".") { safe.removeFirst() }
        if safe.lowercased() == "pdf" || safe.isEmpty { safe = Self.scanName() }
        if !safe.lowercased().hasSuffix(".pdf") { safe += ".pdf" }
        let file = folder.appendingPathComponent(String(safe.suffix(200)))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file)
            addToInbox([file])
            // Copied into the inbox by now, unless HomeClerk is still starting (then it's queued)
            if inbox != nil { try? FileManager.default.removeItem(at: folder) }
        } catch {
            record(.problem, name, "Couldn't add it: \(error.localizedDescription)", nil)
        }
    }

    static func scanName() -> String {
        "Scan \(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))) "
            + "\(Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)).replacingOccurrences(of: ":", with: "."))"
            + ".pdf"
    }
}

/// Finder's "File with HomeClerk" (right-click a PDF ▸ Services, or Quick Actions).
final class HomeClerkServices: NSObject {
    @MainActor @objc func fileWithHomeClerk(_ pasteboard: NSPasteboard, userData: String?,
                                           error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        HomeClerkModel.shared.addToInbox(urls)
    }
}

// MARK: - Notifications, a few at a time

extension HomeClerkModel {
    /// Queues a notification; ones arriving within a few seconds of each other — a stack of scans —
    /// are combined into one.
    func queueNotification(_ title: String, _ body: String, _ path: String, category: String) {
        notificationBatch.append((title, body, path, category))
        notificationFlush?.cancel()
        notificationFlush = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            postBatch()
        }
    }

    private func postBatch() {
        let batch = notificationBatch
        notificationBatch = []
        guard let first = batch.first else { return }
        let content = UNMutableNotificationContent()
        if batch.count == 1 {
            content.title = first.title
            content.body = first.body
            content.userInfo = ["path": first.path]
            content.categoryIdentifier = first.category
        } else {
            let filed = batch.filter { $0.category == Notify.filed }.count
            let review = batch.filter { $0.category == Notify.needsReview }.count
            let duplicates = batch.filter { $0.category == Notify.duplicate }.count
            var parts: [String] = []
            if filed > 0 { parts.append(filed == 1 ? "Filed 1 document" : "Filed \(filed) documents") }
            if review > 0 { parts.append(review == 1 ? "1 needs review" : "\(review) need review") }
            if duplicates > 0 { parts.append(duplicates == 1 ? "1 duplicate" : "\(duplicates) duplicates") }
            content.title = parts.joined(separator: " · ")
            let names = batch.prefix(3).map(\.body)
            content.body = names.joined(separator: ", ") + (batch.count > 3 ? ", and \(batch.count - 3) more" : "")
            content.categoryIdentifier = review > 0 ? Notify.needsReview : Notify.summary
        }
        content.threadIdentifier = content.categoryIdentifier
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: - Monday's summary

extension HomeClerkModel {

    /// Checks hourly; on Monday morning (or the first time HomeClerk runs that week), says what's due
    /// or expiring in the coming week.
    func startWeeklyDigest() {
        digestTask?.cancel()
        digestTask = Task {
            while !Task.isCancelled {
                sendWeeklyDigestIfDue()
                sendDueSoonNotices()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// From 8 a.m. the day before an unpaid bill is due (or on the day, if HomeClerk wasn't open),
    /// one notice per bill with Mark as Paid — unless Reminders is on, which says so already.
    func sendDueSoonNotices(now: Date = .now) {
        guard UserDefaults.standard.object(forKey: DefaultsKey.dueSoonNotices) as? Bool ?? true,
              !(currentSettings ?? SettingsStore.app.load()).createReminders,
              Calendar.current.component(.hour, from: now) >= 8 else { return }
        let today = DocumentProcessor.localToday(), tomorrow = Self.day(1)
        var noticed = UserDefaults.standard.stringArray(forKey: DefaultsKey.noticedDue) ?? []
        for item in upcoming(days: 1) where item.kind == .due && item.date >= today && item.date <= tomorrow {
            let key = "\(item.path)|\(item.date)"
            guard !noticed.contains(key) else { continue }
            noticed.append(key)
            let content = UNMutableNotificationContent()
            content.title = item.date == today ? "Due today" : "Due tomorrow"
            content.body = item.title
            content.categoryIdentifier = Notify.billDue
            content.userInfo = ["path": item.path, "section": Section.upcoming.rawValue]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        }
        UserDefaults.standard.set(Array(noticed.suffix(300)), forKey: DefaultsKey.noticedDue)
    }

    func sendWeeklyDigestIfDue(now: Date = .now) {
        guard UserDefaults.standard.object(forKey: DefaultsKey.weeklyDigest) as? Bool ?? true else { return }
        var calendar = Calendar.current
        calendar.firstWeekday = 2   // weeks start on Monday
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now),
              let mondayMorning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: week.start),
              now >= mondayMorning else { return }
        let last = UserDefaults.standard.object(forKey: DefaultsKey.lastWeeklyDigest) as? Date ?? .distantPast
        guard last < mondayMorning else { return }
        UserDefaults.standard.set(now, forKey: DefaultsKey.lastWeeklyDigest)

        let items = upcoming(days: 7)
        // Work that's been waiting on you: scans in Review for more than three days, and names to confirm
        let stale = now.addingTimeInterval(-3 * 86_400)
        let waitingSince = pending.map { (try? $0.url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? now }
            .filter { $0 < stale }
        guard let digest = WeeklyDigest.compose(items: items, today: DocumentProcessor.localToday(),
                                                waitingScans: waitingSince.count, waitingSince: waitingSince.min(),
                                                namesToConfirm: noticed.count) else { return }
        let content = UNMutableNotificationContent()
        content.title = digest.title
        content.body = digest.body
        content.categoryIdentifier = Notify.weekly
        if digest.opensReview { content.userInfo = ["section": Section.review.rawValue] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: - Claude's monthly limit

extension HomeClerkModel {
    /// This month's estimated Claude spending, and the limit (0 for none).
    var claudeBudget: (spent: Decimal, limit: Decimal) {
        let settings = currentSettings ?? SettingsStore.app.load()
        let ledger = UsageLedger(url: settings.basePath.appendingPathComponent(UsageLedger.fileName))
        return (ledger.spent(), Decimal(settings.claudeMonthlyLimit))
    }

    /// After each paid analysis: refreshes the figure the window shows, and warns once a month on
    /// passing 80% of the limit.
    func checkClaudeBudget() {
        let budget = claudeBudget
        claudeSpent = budget.spent
        guard budget.limit > 0, budget.spent >= budget.limit * 0.8 else { return }
        let month = Date.now.formatted(.iso8601.year().month())
        let key = DefaultsKey.claudeLimitWarned(month: month)
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let content = UNMutableNotificationContent()
        content.title = budget.spent >= budget.limit ? "Claude's monthly limit is reached" : "Claude is near its monthly limit"
        content.body = "\(FinishingPlan.currency(budget.spent)) of \(FinishingPlan.currency(budget.limit)) this month. "
            + (budget.spent >= budget.limit ? "The fallback reads documents until next month." : "Change the limit in Settings ▸ Analysis.")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// In Activity while Claude is held back by its monthly limit.
struct BudgetBanner: View {
    let spent: Decimal
    let limit: Decimal

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "dollarsign.circle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude's monthly limit is reached").font(.callout.weight(.medium))
                Text("\(FinishingPlan.currency(spent)) of \(FinishingPlan.currency(limit)) this month. Until next month, the fallback reads documents — or they wait in Review.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer()
            SettingsLink { Text("Change Limit…") }
        }
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// In Activity when nothing configured can read a scan — a fresh Mac without a key, say.
struct ReadinessBanner: View {
    let model: HomeClerkModel
    let problem: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("HomeClerk can't read documents yet").font(.callout.weight(.medium))
                Text(problem + " Scans wait in Review until something can read them.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer()
            Button("Set Up…") { model.showWelcome = true }
        }
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
