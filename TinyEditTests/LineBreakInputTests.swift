import XCTest
import AppKit
@testable import TinyEdit

/// The buffer is LF-only. Pasted, dropped, or inserted CR / CRLF must be folded before it reaches the
/// store, or saving a CRLF file writes "\r\r\n" and a reopen doubles every pasted line break.
@MainActor
final class LineBreakInputTests: XCTestCase {
    private func makeHost(text: String = "") -> (EditorTextHost, BufferTextStore, NSWindow) {
        let settings = EditorSettings()
        let host = EditorTextHost()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host.scrollView
        let store = BufferTextStore(id: UUID(), text: text, settings: settings)
        host.activate(store, settings: settings)
        return (host, store, window)
    }

    func testPasteFoldsCRLFAndCR() {
        let (host, store, _) = makeHost()
        let pb = NSPasteboard(name: NSPasteboard.Name("TinyEditTests-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("a\r\nb\rc\n", forType: .string)
        XCTAssertTrue(host.textView.readSelection(from: pb, type: .string))
        XCTAssertEqual(store.logicalString(), "a\nb\nc\n")
        XCTAssertEqual(host.textView.selectedRange(), NSRange(location: 6, length: 0))
        XCTAssertTrue(store.undoManager.canUndo)
        store.undoManager.undo()
        XCTAssertEqual(store.logicalString(), "")
    }

    func testPasteWithoutCRIsUntouched() {
        let (host, store, _) = makeHost(text: "xy")
        host.textView.setSelectedRange(NSRange(location: 1, length: 0))
        let pb = NSPasteboard(name: NSPasteboard.Name("TinyEditTests-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("1\n2", forType: .string)
        XCTAssertTrue(host.textView.readSelection(from: pb, type: .string))
        XCTAssertEqual(store.logicalString(), "x1\n2y")
    }

    func testInsertTextFoldsCRLF() {
        let (host, store, _) = makeHost()
        host.textView.insertText("p\r\nq", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(store.logicalString(), "p\nq")
        host.textView.insertText(NSAttributedString(string: "\rr"), replacementRange: host.textView.selectedRange())
        XCTAssertEqual(store.logicalString(), "p\nq\nr")
    }
}
