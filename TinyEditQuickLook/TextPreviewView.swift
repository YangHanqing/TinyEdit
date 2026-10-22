import AppKit

/// Read-only text in the editor's font and colors; token colors go straight onto the storage,
/// since nothing here can be undone, saved or copied with formatting.
enum TextPreviewView {
    @MainActor static func make(text: String, spans: [HighlightSpan]) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.editorBackground
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = true
        view.backgroundColor = Theme.editorBackground
        view.selectedTextAttributes = [.backgroundColor: Theme.textSelection]
        view.textContainerInset = NSSize(width: 12, height: 10)
        let styled = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: Theme.textPrimary,
        ])
        for span in spans where span.range.location >= 0 && NSMaxRange(span.range) <= styled.length {
            styled.addAttribute(.foregroundColor, value: span.kind.color, range: span.range)
        }
        view.textStorage?.setAttributedString(styled)
        return scroll
    }
}
