import XCTest
import AppKit
@testable import TinyEdit

/// Drives the app's own window: what is tested here lives in how SwiftUI and AppKit route updates and keys.
@MainActor
final class EditorSlotTests: XCTestCase {
    private func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func pressEscape(in window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                     isARepeat: false, keyCode: 53)!
        NSApp.sendEvent(event)
        spin(0.1)
    }

    private func ghostVisible(_ textView: NSTextView) -> Bool {
        textView.subviews.contains { String(describing: type(of: $0)) == "InlineHintView" && !$0.isHidden }
    }

    /// The find card takes Escape as a key equivalent; with the editor focused a calculation ghost goes first.
    func testEscapeDismissesTheGhostBeforeTheFindCard() async throws {
        let state = AppState.shared
        for _ in 0..<100 where !state.launchGateOpen { try await Task.sleep(for: .milliseconds(50)) }
        let window = try XCTUnwrap(state.window)
        XCTAssertTrue(state.openTranslationTab("12+30="))
        let id = try XCTUnwrap(state.session.selectedBufferID)
        defer { state.hideFind(); state.removeBuffer(id) }
        state.setLanguage(.plain)
        var settings = state.settings
        if settings.inlineCalculation == .off { settings.inlineCalculation = .plainText; state.updateSettings(settings) }
        state.showFind(replace: false)
        spin(0.3)
        let textView = state.host.textView
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        textView.refreshInlineCalculation()
        XCTAssertTrue(ghostVisible(textView))

        pressEscape(in: window)
        XCTAssertFalse(ghostVisible(textView))
        XCTAssertTrue(state.find.visible)
        pressEscape(in: window)
        XCTAssertFalse(state.find.visible)
    }

    func testLeavingATabWithPreviewShowsTheNewTabsText() async throws {
        let state = AppState.shared
        for _ in 0..<100 where !state.launchGateOpen { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(state.launchGateOpen)
        XCTAssertTrue(state.openTranslationTab("alpha"))
        let plain = try XCTUnwrap(state.session.selectedBufferID)
        XCTAssertTrue(state.openTranslationTab("# Title"))
        let markdown = try XCTUnwrap(state.session.selectedBufferID)
        defer { state.removeBuffer(plain); state.removeBuffer(markdown) }
        state.setLanguage(.markdown)
        state.togglePreview()
        spin(0.3)
        XCTAssertTrue(state.previewVisible)

        for _ in 0..<3 {
            state.selectTab(plain)
            spin(0.3)
            XCTAssertTrue(state.host.layoutManager.textContentManager === state.stores[plain]?.contentStorage)
            XCTAssertEqual(state.host.textView.string, "alpha")
            state.selectTab(markdown)
            spin(0.3)
            XCTAssertEqual(state.host.textView.string, "# Title")
        }
    }
}
