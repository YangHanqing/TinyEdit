import AppKit
import SwiftUI

/// Inline semantics become AppKit attributes here, the one place they turn visual.
enum MarkdownText {
    struct Style: Equatable {
        var size: CGFloat
        var weight: NSFont.Weight = .regular
        var secondary = false
        var alignment: NSTextAlignment = .natural
    }

    @MainActor static func attributed(_ text: AttributedString, style: Style) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment
        let color = style.secondary ? Theme.textSecondary : Theme.textPrimary
        let result = NSMutableAttributedString()
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font: NSFont
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: style.size * 0.92, weight: style.weight)
            } else {
                let strong = intent.contains(.stronglyEmphasized) && style.weight.rawValue < NSFont.Weight.bold.rawValue
                font = .systemFont(ofSize: style.size, weight: strong ? .bold : style.weight)
            }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            if intent.contains(.code) { attributes[.backgroundColor] = Theme.textSecondary.withAlphaComponent(0.15) }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return result
    }

    @MainActor static func plain(_ text: String, font: NSFont, secondary: Bool = false) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font,
            .foregroundColor: secondary ? Theme.textSecondary : Theme.textPrimary])
    }
}

/// Preview text is a read-only NSTextView rather than SwiftUI `Text`, so selecting and copying
/// works the same in every block, table cells and headings included, and a drag that starts on
/// text is never taken as a window-background drag. Wrapping text takes the full proposed width,
/// so a drag may start anywhere on its row.
struct MarkdownTextView: View {
    let text: NSAttributedString
    var wraps = true

    var body: some View {
        // SwiftUI does not ask a platform view for its baseline; list markers align to this one.
        Representable(text: text, wraps: wraps)
            .alignmentGuide(.firstTextBaseline) { _ in Self.firstBaseline(text) }
    }

    @MainActor private static let baselineLayout = NSLayoutManager()
    @MainActor private static let probe = MarkdownSelectableTextView()

    /// The unwrapped width the view itself measures, for sizing table columns before any view exists.
    @MainActor static func naturalWidth(_ text: NSAttributedString) -> CGFloat {
        probe.setContent(text)
        return probe.fittingSize(width: nil).width
    }

    @MainActor static func firstBaseline(_ text: NSAttributedString) -> CGFloat {
        guard text.length > 0, let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return 0 }
        return baselineLayout.defaultBaselineOffset(for: font)
    }

    private struct Representable: NSViewRepresentable {
        let text: NSAttributedString
        let wraps: Bool

        func makeNSView(context: Context) -> MarkdownSelectableTextView { MarkdownSelectableTextView() }

        func updateNSView(_ view: MarkdownSelectableTextView, context: Context) {
            view.openURL = context.environment.openURL
            view.wraps = wraps
            view.setContent(text)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownSelectableTextView, context: Context) -> CGSize? {
            nsView.fittingSize(width: wraps ? proposal.width.flatMap { $0.isFinite ? $0 : nil } : nil)
        }
    }
}

final class MarkdownSelectableTextView: NSTextView, NSTextViewDelegate {
    var openURL: OpenURLAction?
    var wraps = true
    private var measured: (width: CGFloat?, size: CGSize)?

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        // Set after init, which makes the container track the (zero) frame. The width is managed here.
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        // The default maximum is the initial (zero) frame, which would clamp the container to it.
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        isAutomaticLinkDetectionEnabled = false
        selectedTextAttributes = [.backgroundColor: Theme.textSelection]
        linkTextAttributes = [.foregroundColor: Theme.accent, .cursor: NSCursor.pointingHand]
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }

    func setContent(_ text: NSAttributedString) {
        guard let storage = textStorage, !storage.isEqual(to: text) else { return }
        storage.setAttributedString(text)
        measure.storage.setAttributedString(text)
        measured = nil
    }

    /// Measuring has its own layout stack: SwiftUI probes several widths, and AppKit resizes the
    /// view during layout, so neither may move the container the text is drawn in.
    private let measure: (storage: NSTextStorage, layout: NSLayoutManager, container: NSTextContainer) = {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer()
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        return (storage, layout, container)
    }()

    /// Width nil measures one unwrapped line per paragraph (code, the natural width of a table cell).
    func fittingSize(width: CGFloat?) -> CGSize {
        if let measured, measured.width == width { return measured.size }
        measure.container.size = NSSize(width: width.map { max(1, $0) } ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        measure.layout.ensureLayout(for: measure.container)
        let used = measure.layout.usedRect(for: measure.container)
        let size = CGSize(width: width ?? ceil(used.width), height: ceil(used.height))
        measured = (width, size)
        return size
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Draw at the width SwiftUI settled on; a zero frame is only AppKit's initial one.
        guard newSize.width > 0, let container = textContainer else { return }
        let width = wraps ? newSize.width : .greatestFiniteMagnitude
        if container.size.width != width { container.size = NSSize(width: width, height: .greatestFiniteMagnitude) }
    }

    /// One selection at a time: leaving a block clears what was selected in it.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setSelectedRange(NSRange(location: selectedRange().location, length: 0)) }
        return resigned
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) { openURL?(url) }
        return true
    }
}
