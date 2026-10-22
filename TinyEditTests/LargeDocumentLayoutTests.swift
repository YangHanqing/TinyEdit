import XCTest
import AppKit
@testable import TinyEdit

/// Word wrap, zoom and tab switches on documents large enough that a full layout or a walk over one
/// long CoreText line shows up as a hang.
@MainActor
final class LargeDocumentLayoutTests: XCTestCase {
    private var window: NSWindow!
    private let host = EditorTextHost()

    override func setUp() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host.scrollView
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))   // activate() restores scroll asynchronously
        window.displayIfNeeded()
    }

    private var clip: NSClipView { host.scrollView.contentView }

    private func scroll(toY y: CGFloat) {
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        host.scrollView.reflectScrolledClipView(clip)
        settle()
    }

    /// UTF-16 offset of the first character on the top visible line.
    private func topOffset() -> Int {
        let y = max(clip.bounds.minY - host.textView.textContainerOrigin.y, 0)
        let fragment = host.layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: y))!
        let cs = host.layoutManager.textContentManager as! NSTextContentStorage
        let line = fragment.textLineFragments.first { $0.typographicBounds.maxY > y - fragment.layoutFragmentFrame.minY }
        return cs.offset(from: cs.documentRange.location, to: fragment.rangeInElement.location) + (line?.characterRange.location ?? 0)
    }

    private func lines(_ count: Int) -> String {
        (0..<count).map { "\($0) 这是一行测试文本 lorem ipsum dolor sit amet, consectetur adipiscing elit \($0 * 7)" }
            .joined(separator: "\n")
    }

    func testWordWrapToggleKeepsTopLine() {
        var settings = EditorSettings()
        let store = BufferTextStore(id: UUID(), text: lines(20_000), settings: settings)
        host.activate(store, settings: settings)
        settle()
        scroll(toY: host.textView.frame.height / 2)
        let top = topOffset()
        XCTAssertGreaterThan(top, 0)

        settings.wordWrap = false
        host.apply(settings: settings, stores: [store])
        settle()
        XCTAssertEqual(topOffset(), top)

        settings.wordWrap = true
        host.apply(settings: settings, stores: [store])
        settle()
        XCTAssertEqual(topOffset(), top)
    }

    /// A 300 000-character line took about 7 s to unwrap through `scrollRangeToVisible` and AppKit's
    /// content-height estimate, both quadratic in the length of one CoreText line; 2 MB took minutes.
    func testUnwrappedLongLineIsBoundedAndQuick() {
        var settings = EditorSettings()
        let text = String(repeating: "lorem ipsum dolor sit amet ", count: 300_000 / 27)
        let store = BufferTextStore(id: UUID(), text: text, settings: settings)
        host.activate(store, settings: settings)
        settle()

        settings.wordWrap = false
        let start = Date()
        host.apply(settings: settings, stores: [store])
        settle()
        settings.fontSize += 1
        host.apply(settings: settings, stores: [store])
        settle()
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertLessThanOrEqual(host.layoutManager.usageBoundsForTextContainer.width, EditorTextHost.unwrappedLineWidth)
        XCTAssertFalse(host.scrollView.horizontalScroller?.isHidden ?? true)
    }

    func testShortLinesUnwrappedDoNotScrollSideways() {
        var settings = EditorSettings()
        settings.wordWrap = false
        let store = BufferTextStore(id: UUID(), text: lines(200), settings: settings)
        host.activate(store, settings: settings)
        settle()
        XCTAssertLessThanOrEqual(host.textView.frame.width, clip.bounds.width)
        XCTAssertTrue(host.scrollView.horizontalScroller?.isHidden ?? true)
    }

    /// The swap alone left the text view at the previous buffer's size: an empty tab kept the scrollers of
    /// a long one, and a long tab came back one screen tall at the top.
    func testTabSwitchResizesToTheNewBuffer() {
        var settings = EditorSettings()
        settings.wordWrap = false
        let wide = (0..<400).map { "line \($0) " + String(repeating: "wide ", count: $0 % 5 == 0 ? 300 : 3) }.joined(separator: "\n")
        let a = BufferTextStore(id: UUID(), text: wide, settings: settings)
        let c = BufferTextStore(id: UUID(), text: "", settings: settings)
        host.apply(settings: settings, stores: [a, c])
        host.activate(a, settings: settings)
        settle()
        let tall = host.textView.frame.size
        XCTAssertGreaterThan(tall.width, clip.bounds.width)
        XCTAssertGreaterThan(tall.height, clip.bounds.height)
        scroll(toY: tall.height / 2)

        host.activate(c, settings: settings)
        settle()
        XCTAssertLessThanOrEqual(host.textView.frame.width, clip.bounds.width)
        XCTAssertLessThanOrEqual(host.textView.frame.height, clip.bounds.height)
        XCTAssertTrue(host.scrollView.horizontalScroller?.isHidden ?? true)
        XCTAssertTrue(host.scrollView.verticalScroller?.isHidden ?? true)

        host.activate(a, settings: settings)
        settle()
        XCTAssertGreaterThan(host.textView.frame.height, clip.bounds.height)
        XCTAssertGreaterThan(clip.bounds.minY, 0)
    }

    func testTextContainerOriginIsTheInset() {
        host.textView.textContainerInset = NSSize(width: 8, height: 4)
        XCTAssertEqual(host.textView.textContainerOrigin, NSPoint(x: 8, y: 4))
    }
}
