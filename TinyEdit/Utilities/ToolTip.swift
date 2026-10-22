import AppKit
import SwiftUI

extension View {
    /// A tooltip shown by AppKit (`NSView.toolTip`) instead of SwiftUI's `.help`. On macOS 15 `.help`
    /// crashes when its view is removed while the mouse is over it (the next mouse-exit asks SwiftUI's
    /// tooltip responder for its text, and that reads a released attribute), e.g. a card's Decode or
    /// Dismiss button that hides itself. An AppKit tooltip goes away with its view.
    func toolTip(_ text: String) -> some View {
        overlay(ToolTipArea(text: text).allowsHitTesting(false))
            .accessibilityHint(text)
    }
}

private struct ToolTipArea: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView { PassThroughView() }

    func updateNSView(_ view: NSView, context: Context) {
        let tip = text.isEmpty ? nil : text
        if view.toolTip != tip { view.toolTip = tip }
    }

    /// Carries only the tooltip rect; clicks and drags reach whatever is underneath.
    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var mouseDownCanMoveWindow: Bool { true }
    }
}
