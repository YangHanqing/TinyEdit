import XCTest
import AppKit
@testable import TinyEdit

/// Wrapped text must never leave a horizontal offset: there is no horizontal scroller to show it.
@MainActor
final class WordWrapTests: XCTestCase {
    private var window: NSWindow!
    private let host = EditorTextHost()

    override func setUp() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host.scrollView
    }

    /// While line numbers show, the leftmost clip origin is minus the ruler width.
    private var leftmostX: CGFloat { -(host.ruler?.ruleThickness ?? 0) }

    private func settle(_ store: BufferTextStore) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))   // activate() restores scroll asynchronously
        host.layoutManager.ensureLayout(for: store.contentStorage.documentRange)
        host.scrollView.tile()
    }

    func testRestoredScrollKeepsTextClearOfRuler() {
        let settings = EditorSettings()
        let store = BufferTextStore(id: UUID(), text: "hello", settings: settings)
        host.activate(store, settings: settings)
        settle(store)
        XCTAssertLessThan(leftmostX, 0)
        XCTAssertEqual(host.scrollView.contentView.bounds.minX, leftmostX)
    }

    func testLongUnbrokenTextWrapsWithinVisibleWidth() {
        let settings = EditorSettings()
        let text = String(repeating: "abcdefghij", count: 400) + " https://example.com/" + String(repeating: "x", count: 600)
            + "\n" + String(repeating: "中文没有空格", count: 300)
        let store = BufferTextStore(id: UUID(), text: text, settings: settings)
        host.activate(store, settings: settings)
        for width in [600.0, 400.0, 700.0] {
            window.setContentSize(NSSize(width: width, height: 400))
            settle(store)
            let clip = host.scrollView.contentView.bounds
            XCTAssertLessThanOrEqual(host.textView.frame.maxX, clip.maxX, "width \(width)")
            XCTAssertLessThanOrEqual(host.layoutManager.usageBoundsForTextContainer.maxX, host.textView.frame.width, "width \(width)")
            XCTAssertEqual(clip.minX, leftmostX, "width \(width)")
        }
    }

    func testTurningWrapOnDropsHorizontalOffset() {
        var settings = EditorSettings()
        settings.wordWrap = false
        let store = BufferTextStore(id: UUID(), text: String(repeating: "wide ", count: 2000), settings: settings)
        host.activate(store, settings: settings)
        settle(store)
        host.scrollView.contentView.scroll(to: NSPoint(x: 500, y: 0))
        XCTAssertEqual(host.scrollView.contentView.bounds.minX, 500)

        settings.wordWrap = true
        host.apply(settings: settings, stores: [store])
        settle(store)
        XCTAssertEqual(host.scrollView.contentView.bounds.minX, leftmostX)
    }
}
