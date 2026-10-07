// What's New: shown once after an update that adds features, and from Help ▸ What's New. Not on a
// first run — the Setup Assistant covers everything then.

import HomeClerkKit
import SwiftUI

/// A feature in the sheet.
struct WhatsNewItem: Identifiable {
    var symbol: String
    var title: String
    var detail: String
    var id: String { title }
}

enum WhatsNew {
    /// Raise this when adding to `items`, so people who've seen the sheet see it again.
    static let edition = 2

    /// Shown to someone who used the app under its old name.
    static let renamed = WhatsNewItem(symbol: "signature", title: "DocuSort is now HomeClerk",
        detail: "Same app, new name. Your settings, folder, Reminders list, Claude key, and Mail rule carried over. Move the old DocuSort app to the Trash.")

    static var items: [WhatsNewItem] {
        (UserDefaults.standard.persistentDomain(forName: Legacy.defaultsDomain) != nil ? [renamed] : []) + features
    }

    /// What's new since the last edition; the first run's Setup Assistant covers everything else.
    static let features: [WhatsNewItem] = [
        WhatsNewItem(symbol: "folder.badge.gearshape", title: "New kinds of documents",
                     detail: "Computers, phones, and other devices get their own folder, and anything tagged work-expense is gathered in Employment - Expenses."),
        WhatsNewItem(symbol: "folder.badge.questionmark", title: "Move your folder",
                     detail: "Settings ▸ General ▸ Move… takes your HomeClerk folder anywhere — another drive or iCloud Drive — and reminders and the Mail script follow. Moved it in Finder? HomeClerk asks where it went."),
        WhatsNewItem(symbol: "stethoscope", title: "Library Health",
                     detail: "File ▸ Check Library Health finds records whose PDF is gone and PDFs the Library doesn't know, and Sync with Folders fixes them in one step."),
        WhatsNewItem(symbol: "clock.badge.checkmark", title: "Keep All Like This",
                     detail: "In Tidy Up ▸ Past Keep Period, stop suggesting a whole kind of document — vehicle and home records are now kept for good anyway."),
        WhatsNewItem(symbol: "memorychip", title: "Ollama lets go of memory",
                     detail: "The local model is unloaded after a few idle minutes, so leaving HomeClerk running costs little. Settings ▸ Ollama ▸ Memory."),
    ]
}

extension HomeClerkModel {
    /// After an update with new features, once. Someone setting up for the first time just
    /// starts at this edition.
    func offerWhatsNew() {
        let seen = UserDefaults.standard.integer(forKey: DefaultsKey.whatsNewSeen)
        guard seen < WhatsNew.edition else { return }
        UserDefaults.standard.set(WhatsNew.edition, forKey: DefaultsKey.whatsNewSeen)
        if UserDefaults.standard.bool(forKey: DefaultsKey.setupComplete), !showWelcome { showWhatsNew = true }
    }
}

struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("What's New in HomeClerk").font(.title2.weight(.semibold))
            ForEach(WhatsNew.items) { item in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: item.symbol)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.headline)
                        Text(item.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                Spacer()
                Button("Continue") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
