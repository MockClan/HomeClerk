// The menu bar icon's menu.

import AppKit
import CoreSpotlight
import HomeClerkKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// The menu bar icon's menu: status, review, pause, and the window.
struct MenuBarContent: View {
    let model: HomeClerkModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusText)
        if model.needsReview > 0 {
            Button(model.needsReview == 1 ? "1 Scan Needs Review" : "\(model.needsReview) Scans Need Review") { show(.review) }
        }
        Divider()
        if model.state == .paused {
            Button("Resume Watching") { model.resume() }
        } else {
            Button("Pause Watching") { model.pause() }.disabled(model.state != .watching)
        }
        let recent = model.library.documents.sorted { $0.filedAt > $1.filedAt }.prefix(5)
        if !recent.isEmpty {
            Divider()
            Text("Recently Filed")
            ForEach(Array(recent)) { entry in
                Button(FiledScreen.title(entry)) { NSWorkspace.shared.open(URL(fileURLWithPath: entry.path)) }
            }
        }
        Divider()
        Button("Open HomeClerk") { show(nil) }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit HomeClerk") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func show(_ section: Section?) {
        if let section { model.section = section }
        openWindow(id: "main")
        NSApp.activate()
    }
}
