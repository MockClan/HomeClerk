// A PDF shown in a section, kept on the page you were reading as the file changes.

import AppKit
import HomeClerkKit
import PDFKit
import QuickLook
import SwiftUI

struct PDFPreview: NSViewRepresentable {
    let url: URL
    /// Bumped when the file changed in place (rotated, say), so it's read again.
    var revision = 0
    /// The page showing (0-based), for actions on "this page".
    var page: Binding<Int>?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .windowBackgroundColor
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.page = page
        guard view.document?.documentURL != url || context.coordinator.revision != revision else { return }
        // Read again, staying on the same page when it's the same file
        let sameFile = view.document?.documentURL == url
        let index = sameFile ? view.currentPage.flatMap { view.document?.index(for: $0) } ?? 0 : 0
        context.coordinator.revision = revision
        view.document = PDFDocument(url: url)
        if let target = view.document?.page(at: index) { view.go(to: target) }
        if !sameFile { page?.wrappedValue = 0 }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        var page: Binding<Int>?
        var revision = 0

        func observe(_ view: PDFView) {
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: view)
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView, let current = view.currentPage,
                  let index = view.document?.index(for: current) else { return }
            page?.wrappedValue = index
        }
    }
}
