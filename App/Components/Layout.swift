// Layout pieces the sections share: a resizable pane divider and tables that never scroll sideways.

import AppKit
import HomeClerkKit
import PDFKit
import QuickLook
import SwiftUI

extension View {
    /// The table's columns shrink to fit, so it never needs a sideways scroll bar — which otherwise
    /// flashes while the sidebar slides, as the columns catch up with the narrower table.
    func columnsFitWithoutScrolling() -> some View { scrollIndicators(.never, axes: .horizontal) }
}

/// A divider that resizes the pane before it by dragging, as Mail's message list resizes.
struct ResizableDivider: View {
    @Binding var width: Double
    var range: ClosedRange<Double> = 200...520
    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        guard inside != hovering else { return }
                        hovering = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    // Leaving the section while over the divider mustn't leave the resize pointer behind
                    .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let origin = start ?? width
                            start = origin
                            width = min(max(origin + drag.translation.width, range.lowerBound), range.upperBound)
                        }
                        .onEnded { _ in start = nil })
            }
            // VoiceOver can't drag; it adjusts instead (swipe up or down)
            .accessibilityElement()
            .accessibilityLabel("List width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: width = min(width + 40, range.upperBound)
                case .decrement: width = max(width - 40, range.lowerBound)
                @unknown default: break
                }
            }
    }
}
