// HomeClerk.app — files scanned household documents.
//
// Opening the app starts watching the inbox and shows each document from the moment it arrives
// until it's filed, with a notification per document. Quitting the app (⌘Q or closing the
// window) stops it, so nothing keeps running in the background. PDFs dropped on the window or
// the app icon — or sent by Image Capture's "Scan To" — are copied into the inbox.
//
// All of the work — OCR, analysis, filing, the text layer, tags, and Reminders — happens in this
// process, in HomeClerkKit. Built from project.yml (XcodeGen) with Xcode. This file is the app and
// its delegate; Model/ holds its state, Screens/ the window's sections, Settings/ the Settings
// window, and Components/ the pieces they share.

import AppKit
import CoreSpotlight
import HomeClerkKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@main
struct HomeClerkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Once, before anything reads settings: carry over what the app left under its old name,
        // DocuSort. Not when a test points the app at a scratch folder, so a test copy never
        // touches the real preferences or Keychain.
        let environment = ProcessInfo.processInfo.environment
        if !environment.keys.contains(where: { $0.lowercased() == "homeclerk_homeclerk__basepath" }),
           !UserDefaults.standard.bool(forKey: Legacy.migratedKey) {
            Legacy.migratePreferences(from: UserDefaults.standard.persistentDomain(forName: Legacy.defaultsDomain),
                                      to: .standard)
            Legacy.migrateAPIKey()
        }
    }

    var body: some Scene {
        Window("HomeClerk", id: "main") {
            MainView(model: .shared)
                .frame(minWidth: 860, minHeight: 520)
        }
        .defaultSize(width: 1000, height: 640)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About HomeClerk") { Project.showAbout() }
            }
            CommandGroup(replacing: .newItem) {}   // one window; no File ▸ New
            CommandGroup(replacing: .importExport) {
                Button("Export Tax Documents…") { HomeClerkModel.shared.showTaxExport = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Year in Review…") { HomeClerkModel.shared.showYearInReview = true }
                Button("Check Library Health…") {
                    HomeClerkModel.shared.section = .tidy
                    HomeClerkModel.shared.showLibraryHealth = true
                }
            }
            ImportFromDevicesCommands()   // File ▸ Import from iPhone ▸ Scan Documents
            CommandGroup(after: .appSettings) {
                Button("Setup Assistant…") { HomeClerkModel.shared.showWelcome = true }
            }
            CommandGroup(replacing: .help) {
                Button("What's New in HomeClerk") { HomeClerkModel.shared.showWhatsNew = true }
                Button("HomeClerk on GitHub") { NSWorkspace.shared.open(Project.repository) }
                Button("Report a Problem…") { NSWorkspace.shared.open(Project.issues) }
                Divider()
                Button("Copy Diagnostics") { HomeClerkModel.shared.copyDiagnostics() }
            }
            SidebarCommands()
            GoCommands(model: .shared)
            DocumentCommands()
        }

        Settings {
            SettingsView(model: .shared)
        }

        MenuBarExtra {
            MenuBarContent(model: .shared)
        } label: {
            Image(systemName: HomeClerkModel.shared.menuSymbol)
                .accessibilityLabel("HomeClerk: \(HomeClerkModel.shared.statusText)")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let services = HomeClerkServices()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // A first run asks once setup is done, when the request makes sense
        if UserDefaults.standard.bool(forKey: DefaultsKey.setupComplete) { HomeClerkModel.shared.askForNotifications() }
        center.setNotificationCategories(Notify.categories)
        // Finder's "File with HomeClerk"
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        HomeClerkModel.shared.start()
        HomeClerkModel.shared.offerSetupIfNew()
        HomeClerkModel.shared.offerWhatsNew()
    }

    // Keeps watching from the menu bar after the window is closed
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = HomeClerkModel.shared
        model.stopOllama()
        return model.stop { NSApp.reply(toApplicationShouldTerminate: true) } ? .terminateLater : .terminateNow
    }

    /// A filed document picked in Spotlight: open it.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let path = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let organized = HomeClerkModel.shared.organized,
              FileOrganizer.isInside(URL(fileURLWithPath: path), organized),   // only documents HomeClerk filed
              FileManager.default.fileExists(atPath: path) else { return false }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        return true
    }

    /// PDFs dropped on the app icon or sent by Image Capture's "Scan To".
    func application(_ application: NSApplication, open urls: [URL]) {
        HomeClerkModel.shared.addToInbox(urls)
    }

    // Notification callbacks can arrive off the main thread
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let path = response.notification.request.content.userInfo["path"] as? String
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        let sectionName = response.notification.request.content.userInfo["section"] as? String
        Task { @MainActor in
            let url = path.map { URL(fileURLWithPath: $0) }
            switch action {
            case Notify.open: if let url { NSWorkspace.shared.open(url) }
            case Notify.review:
                HomeClerkModel.shared.section = .review
                NSApp.activate()
            case Notify.showUpcoming:
                HomeClerkModel.shared.section = .upcoming
                NSApp.activate()
            case Notify.markPaid:
                if let path {
                    HomeClerkModel.shared.setPaid(true, path: path)
                }
            default:
                // Clicking the notification itself, or "Show in Finder" (a bill's notice opens Upcoming)
                if let url, category != Notify.billDue {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    // A summary of several: the window, at the section it's about
                    let named = sectionName.flatMap(Section.init(rawValue:))
                    HomeClerkModel.shared.section = named ?? (category == Notify.weekly ? .upcoming
                        : category == Notify.needsReview ? .review : .activity)
                    NSApp.activate()
                }
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])   // show banners even while the window is in front
    }
}
