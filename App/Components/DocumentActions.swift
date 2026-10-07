// What every list of documents offers: Open, Quick Look, Show in Finder, dragging out, and Read Again.

import AppKit
import HomeClerkKit
import PDFKit
import QuickLook
import SwiftUI

extension DocumentIndex.Entry: @retroactive Identifiable {
    public var id: String { path }
}

/// One button per reader, for the Read Again menus in Review and Tidy Up.
struct ReadAgainButtons: View {
    let read: (AIProvider) -> Void

    var body: some View {
        Button("With Claude (about 2¢ each)") { read(.claude) }
        Button("With Ollama") { read(.ollama) }
        Button("With Apple Intelligence") { read(.apple) }
    }
}

struct FileMenu: View {
    let path: String
    var preview: Binding<URL?>? = nil
    var body: some View {
        Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        if let preview { Button("Quick Look") { preview.wrappedValue = URL(fileURLWithPath: path) } }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        let originals = PDFTransformation.originalsFolder(for: URL(fileURLWithPath: path))
        if FileManager.default.fileExists(atPath: originals.path) {
            Button("Show PDF Originals") { NSWorkspace.shared.open(originals) }
                .help("Exact copies saved before PDF transformations in this folder; never automatically cleared.")
        }
    }
}

/// Dragging a document out of HomeClerk — to Finder, Mail, or any app that takes files.
enum FileDrag {
    static func provider(_ path: String) -> NSItemProvider {
        NSItemProvider(contentsOf: URL(fileURLWithPath: path)) ?? NSItemProvider()
    }
}

extension View {
    /// Space bar opens Quick Look on the selected document, as in Finder; arrow keys move through `all`.
    func quickLookOnSpace(selected: URL?, all: [URL], preview: Binding<URL?>) -> some View {
        quickLookPreview(preview, in: all)
            .onKeyPress(.space) {
                guard let selected else { return .ignored }
                preview.wrappedValue = preview.wrappedValue == nil ? selected : nil
                return .handled
            }
    }
}
