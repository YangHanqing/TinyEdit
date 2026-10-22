import XCTest
import AppKit
@testable import TinyEdit

/// End to end through AppState, the shared text view and TextKit 2 rendering attributes:
/// a new Untitled tab switched to JavaScript is colored, and the colors actually draw.
@MainActor
final class HighlightPipelineTests: XCTestCase {
    private var root: URL!
    private var window: NSWindow!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("HL-\(UUID().uuidString)")
    }

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        try? FileManager.default.removeItem(at: root)
    }

    private let js = "const x = 42; // note\nlet s = \"str\";\nfunction f() { return true; }\n"

    /// Launch, add a fresh Untitled tab, and put the shared text view in a window the way RootView does.
    private func launchWithNewTab() async -> AppState {
        let s = AppState(root: root, autoRestore: false)
        await s.restore()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = s.host.scrollView
        s.newTab()
        s.host.activate(s.activeStore!, settings: s.settings)   // what EditorView.updateNSView does
        return s
    }

    /// Foreground rendering attribute at a UTF-16 offset of the active buffer.
    private func color(at offset: Int, in s: AppState) -> NSColor? {
        let cs = s.activeStore!.contentStorage
        guard let loc = cs.location(cs.documentRange.location, offsetBy: offset) else { return nil }
        var found: NSColor?
        s.host.layoutManager.enumerateRenderingAttributes(from: loc, reverse: false) { _, attrs, range in
            if range.contains(loc) { found = attrs[.foregroundColor] as? NSColor }
            return false
        }
        return found
    }

    /// Polls the main actor until `cond` holds; returns the elapsed time, or nil on timeout.
    private func waitFor(_ timeout: Duration = .seconds(2), _ cond: () -> Bool) async -> Duration? {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if cond() { return ContinuousClock.now - start }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    private func offset(of needle: String) -> Int { (js as NSString).range(of: needle).location }

    private func assertJSColors(_ s: AppState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(color(at: offset(of: "const"), in: s), TokenKind.keyword.color, "const", file: file, line: line)
        XCTAssertEqual(color(at: offset(of: "42"), in: s), TokenKind.number.color, "42", file: file, line: line)
        XCTAssertEqual(color(at: offset(of: "// note"), in: s), TokenKind.comment.color, "comment", file: file, line: line)
        XCTAssertEqual(color(at: offset(of: "\"str\""), in: s), TokenKind.string.color, "string", file: file, line: line)
        XCTAssertEqual(color(at: offset(of: "function"), in: s), TokenKind.keyword.color, "function", file: file, line: line)
        XCTAssertEqual(color(at: offset(of: "true"), in: s), TokenKind.boolean.color, "true", file: file, line: line)
        XCTAssertNil(color(at: offset(of: "x ="), in: s), "identifier stays uncolored", file: file, line: line)
    }

    /// New tab -> JavaScript -> paste code.
    func testNewTabSwitchedToJavaScriptThenPasted() async throws {
        let s = await launchWithNewTab()
        s.setLanguage(.javascript)
        XCTAssertEqual(s.status.languageLabel, "JavaScript")

        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString(js, forType: .string)
        XCTAssertTrue(s.host.textView.readSelection(from: pb, type: .string))

        let latency = await waitFor { color(at: offset(of: "const"), in: s) != nil }
        XCTAssertNotNil(latency, "no highlight after paste")
        assertJSColors(s)
    }

    /// New tab -> type code as Plain Text -> switch to JavaScript.
    func testExistingTextColorsWhenLanguageChanges() async throws {
        let s = await launchWithNewTab()
        s.host.textView.insertText(js, replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(color(at: offset(of: "const"), in: s), "plain text must not be colored")

        s.setLanguage(.javascript)
        let latency = await waitFor { color(at: offset(of: "const"), in: s) != nil }
        XCTAssertNotNil(latency, "no highlight after switching to JavaScript")
        assertJSColors(s)

        s.setLanguage(.plain)
        _ = await waitFor { color(at: offset(of: "const"), in: s) == nil }
        XCTAssertNil(color(at: offset(of: "const"), in: s), "switching back to Plain Text clears colors")
    }

    private let swiftSource = """
    import SwiftUI
    import UIKit

    /// 收藏详情。
    struct CollectionDetailView: View {
        @Environment(\\.dismiss) private var dismiss
        @Environment(AppEnvironment.self) private var env
        let itemID: UUID

        @State private var item: CollectionItemRecord?
        @State private var toast: String?
        @State private var isRenaming = false
        @State private var draftName = ""
        @State private var isScreenCaptured = Self.currentScreenCaptured()

        var body: some View {
            Group {
                if let item {
                    content(item: item)
                } else {
                    ProgressView()
                }
            }
            .background(Color.gray)
        }
    }

    """

    /// The screenshot's file: every line's tokens are colored, not just one line.
    func testSwiftScreenshotSourceColorsEveryLine() async throws {
        let s = await launchWithNewTab()
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString(String(repeating: swiftSource, count: 4), forType: .string)
        XCTAssertTrue(s.host.textView.readSelection(from: pb, type: .string))
        s.setLanguage(.swift)
        let ns = s.activeStore!.textStorage.mutableString
        func at(_ needle: String, from: Int = 0) -> Int {
            ns.range(of: needle, range: NSRange(location: from, length: ns.length - from)).location
        }
        _ = await waitFor { color(at: at("import"), in: s) != nil }
        let checks: [(String, TokenKind)] = [
            ("import", .keyword), ("/// 收藏", .comment), ("struct", .keyword), ("@Environment(\\", .attribute),
            ("private var dismiss", .keyword), ("let itemID", .keyword), ("@State", .attribute),
            ("false", .boolean), ("\"\"", .string), ("var body", .keyword), ("if let", .keyword),
        ]
        for (needle, kind) in checks {
            XCTAssertEqual(color(at: at(needle), in: s), kind.color, needle)
        }
        // A copy far below the first screen is colored too.
        let last = at("import UIKit", from: ns.length - swiftSource.utf16.count)
        XCTAssertEqual(color(at: last, in: s), TokenKind.keyword.color, "last copy")
    }

    // MARK: Redraw of lines already on screen

    /// Hooks TextKit 2's per-line view (`_NSTextViewportElementView -drawRect:`) and records, for each
    /// view, whether colors were present when it last drew. Pixel checks through `cacheDisplay` force
    /// every view to redraw, so they cannot catch a line still showing its old, uncolored drawing.
    nonisolated(unsafe) static var drewWithColors: [ObjectIdentifier: Bool] = [:]
    nonisolated(unsafe) static var colorsPresent: (@MainActor () -> Bool)?
    static let lineDrawHookInstalled: Bool = {
        guard let cls = NSClassFromString("_NSTextViewportElementView"),
              let m = class_getInstanceMethod(cls, NSSelectorFromString("drawRect:")) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, NSRect) -> Void
        let original = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject, NSRect) -> Void = { view, rect in
            MainActor.assumeIsolated {
                if let probe = HighlightPipelineTests.colorsPresent {
                    HighlightPipelineTests.drewWithColors[ObjectIdentifier(view)] = probe()
                }
            }
            original(view, NSSelectorFromString("drawRect:"), rect)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
        return true
    }()

    private func visibleLineViews(_ s: AppState) -> [NSView] {
        var out: [NSView] = []
        func walk(_ v: NSView) {
            if "\(type(of: v))" == "_NSTextViewportElementView", !v.isHiddenOrHasHiddenAncestor { out.append(v) }
            v.subviews.forEach(walk)
        }
        walk(s.host.textView)
        return out
    }

    /// Visible lines whose last drawing does not match the current coloring.
    private func staleLines(_ s: AppState, expectColors: Bool) -> Int {
        let views = visibleLineViews(s)
        XCTAssertGreaterThan(views.count, 0)
        return views.filter { Self.drewWithColors[ObjectIdentifier($0)] != expectColors }.count
    }

    /// Lets AppKit lay out and Core Animation commit, which is when layer-backed line views draw.
    private func settle() async {
        window.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        window.displayIfNeeded()
    }

    private func launchShowing(_ text: String) async throws -> AppState {
        try XCTSkipUnless(Self.lineDrawHookInstalled, "TextKit 2 line view class not found on this OS")
        let s = await launchWithNewTab()
        Self.drewWithColors = [:]
        Self.colorsPresent = { [unowned self] in self.color(at: 0, in: s) != nil }
        addTeardownBlock { @MainActor in Self.colorsPresent = nil }
        window.orderFrontRegardless()
        s.host.textView.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(300))
        await settle()
        return s
    }

    /// The reported bug: switching an on-screen tab to a language must redraw every visible line,
    /// not only a line that happens to be redrawn for another reason.
    func testLanguageChangeRedrawsEveryVisibleLine() async throws {
        let s = try await launchShowing(swiftSource)
        XCTAssertEqual(staleLines(s, expectColors: false), 0)

        s.setLanguage(.swift)
        _ = await waitFor { color(at: 0, in: s) != nil }
        await settle()
        XCTAssertEqual(staleLines(s, expectColors: true), 0, "visible lines still show no colors")

        s.setLanguage(.plain)
        _ = await waitFor { color(at: 0, in: s) == nil }
        await settle()
        XCTAssertEqual(staleLines(s, expectColors: false), 0, "visible lines still show old colors")
    }

    /// Paste into a tab that is already JavaScript: the pasted lines draw uncolored, then pick up colors.
    func testPasteIntoJavaScriptTabRedrawsColoredLines() async throws {
        let s = try await launchShowing("")
        s.setLanguage(.javascript)
        s.host.textView.insertText(String(repeating: js, count: 10), replacementRange: NSRange(location: 0, length: 0))
        await settle()
        XCTAssertGreaterThan(staleLines(s, expectColors: true), 0, "precondition: lines drawn before the debounce")
        _ = await waitFor { color(at: 0, in: s) != nil }
        await settle()
        XCTAssertEqual(staleLines(s, expectColors: true), 0, "colors arrived but lines were not redrawn")
    }

    /// Lines that were off screen when colors changed show the new colors when scrolled back.
    func testLinesScrolledBackInAfterColorChangeAreRedrawn() async throws {
        let s = try await launchShowing(String(repeating: swiftSource, count: 20))
        let tv = s.host.textView
        tv.scrollToEndOfDocument(nil)
        await settle()

        s.setLanguage(.swift)
        _ = await waitFor { color(at: 0, in: s) != nil }
        await settle()

        tv.scrollToBeginningOfDocument(nil)
        s.host.layoutManager.textViewportLayoutController.layoutViewport()
        await settle()
        XCTAssertLessThan(s.host.scrollView.contentView.bounds.origin.y, 20)   // back at the top (inset aside)
        XCTAssertEqual(staleLines(s, expectColors: true), 0, "top lines kept their uncolored drawing")
    }
}
