import AppKit
import QuickLookUI
import SwiftUI

/// Quick Look (Space in Finder) for Markdown files: the editor's preview, read-only. The sandbox
/// reaches only the previewed file and the extension has no network, so images show as their alt text.
final class PreviewViewController: NSViewController, QLPreviewingController {
    override func loadView() {
        view = NSView()
        preferredContentSize = NSSize(width: 800, height: 600)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let blocks: [MarkdownNode]? = try await Task.detached(priority: .userInitiated) {
            // Same decoding and size policy as opening the file in the editor and its preview pane.
            let text = try FileLoader.load(from: url).logicalLF
            guard text.utf8.count <= HighlightPolicy.offLimit else { return nil }
            return try? MarkdownDocument.parse(text)
        }.value
        let page = MarkdownPage(blocks: blocks ?? [],
                                message: blocks == nil ? String(localized: "Preview unavailable") : nil)
            .environment(\.markdownDocumentURL, url)
            .environment(\.markdownImagesLoad, false)
        let host = NSHostingView(rootView: page)
        host.frame = view.bounds
        host.autoresizingMask = [.width, .height]
        view.addSubview(host)
    }
}
