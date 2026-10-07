// Page: how every section lays out its title, status, toolbar control, and content.

import AppKit
import HomeClerkKit
import PDFKit
import QuickLook
import SwiftUI

enum Layout {
    /// Space between the window's content and its edges, in every section.
    static let margin: CGFloat = 20
}

/// Every section the same way: its name as the window title, a line of status as the subtitle,
/// the section's own control in the middle of the toolbar, and the content below.
struct Page<Accessory: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .toolbar {
                // A group, so each control becomes its own toolbar item with its own accessibility
                // label (one item holding several controls gave VoiceOver a neighbour's name)
                if Accessory.self != EmptyView.self {
                    ToolbarItemGroup(placement: .principal) { accessory }
                }
            }
    }
}

extension Page where Accessory == EmptyView {
    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}
