import AppKit
import QuickLookUI
import SwiftUI

/// Quick Look (Space in Finder) for text files: Markdown as the editor's preview renders it, other
/// text highlighted as the editor colors it, both read-only. The sandbox reaches only the previewed
/// file and the extension has no network, so Markdown images show as their alt text.
final class PreviewViewController: NSViewController, QLPreviewingController {
    override func loadView() {
        view = NSView()
        preferredContentSize = NSSize(width: 800, height: 600)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let content = try await Task.detached(priority: .userInitiated) { try QuickLookContent.load(url) }.value
        let preview: NSView
        switch content {
        case .markdown(let blocks):
            preview = NSHostingView(rootView: MarkdownPage(blocks: blocks ?? [],
                                                           message: blocks == nil ? String(localized: "Preview unavailable") : nil)
                .environment(\.markdownDocumentURL, url)
                .environment(\.markdownImagesLoad, false))
        case .text(let text, let spans):
            preview = TextPreviewView.make(text: text, spans: spans)
        }
        preview.frame = view.bounds
        preview.autoresizingMask = [.width, .height]
        view.addSubview(preview)
    }
}
