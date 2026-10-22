import SwiftUI

/// Thin bridge. `updateNSView` swaps stores and applies settings; it never assigns text.
struct EditorView: NSViewRepresentable {
    let host: EditorTextHost
    let store: BufferTextStore?
    let allStores: [BufferTextStore]
    let settings: EditorSettings

    func makeNSView(context: Context) -> NSScrollView { host.scrollView }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        host.apply(settings: settings, stores: allStores)
        guard let store else { return }
        let changed = host.activeStore !== store
        host.activate(store, settings: settings)
        if changed {
            DispatchQueue.main.async { host.focus() }
        }
    }
}
