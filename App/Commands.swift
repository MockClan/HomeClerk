// The Go and Document menus.

import AppKit
import HomeClerkKit
import PDFKit
import QuickLook
import SwiftUI

/// Go: each section by ⌘1 onward, in sidebar order, and HomeClerk's folders in Finder.
struct GoCommands: Commands {
    let model: HomeClerkModel

    var body: some Commands {
        CommandMenu("Go") {
            ForEach(Array(Section.allCases.enumerated()), id: \.element) { index, section in
                Button(section.rawValue) { model.section = section }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Button("Search Documents") {
                model.section = .search
                model.focusSearch = true
            }
            .keyboardShortcut("f", modifiers: [.command, .option])   // as Mail's mailbox search
            Divider()
            Button("Inbox Folder") { open(model.inbox) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Organized Folder") { open(model.organized) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Review Folder") { open(model.review) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}

/// Document: what to do with the scan selected in Review.
struct DocumentCommands: Commands {
    @FocusedValue(\.review) private var review

    var body: some Commands {
        CommandMenu("Document") {
            Button("File") { review?.fileAsProposed?() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(review?.fileAsProposed == nil)
            Button("Send Back to the Inbox") { review?.analyzeAgain() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(review == nil)
            Divider()
            Button("Open") { review?.open() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(review == nil)
            Button("Show in Finder") { review?.showInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(review == nil)
            Divider()
            // As Preview rotates
            Button("Rotate Left") { review?.rotate(-1, false) }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(review == nil)
            Button("Rotate Right") { review?.rotate(1, false) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(review == nil)
            Button("Rotate All Pages Left") { review?.rotate(-1, true) }
                .disabled(review == nil)
            Button("Rotate All Pages Right") { review?.rotate(1, true) }
                .disabled(review == nil)
        }
    }
}
