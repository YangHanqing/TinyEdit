import XCTest
import AppKit
@testable import TinyEdit

/// Spaces and tabs inside the selection are marked; nothing outside it is.
@MainActor
final class WhitespaceMarksTests: XCTestCase {
    private var window: NSWindow!
    private let host = EditorTextHost()

    override func setUp() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host.scrollView
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.displayIfNeeded()
    }

    private func show(_ text: String) {
        let settings = EditorSettings()
        host.activate(BufferTextStore(id: UUID(), text: text, settings: settings), settings: settings)
        settle()
    }

    func testMarksOnlySelectedBlanks() {
        show("a \tb\u{3000}c\u{A0}d e")
        host.textView.setSelectedRange(NSRange(location: 0, length: 8))
        settle()
        let marks = host.textView.visibleWhitespaceMarks
        XCTAssertEqual(marks.map(\.kind), [.space, .tab, .ideographicSpace, .noBreakSpace])
        let space = marks[0].rect, tab = marks[1].rect
        XCTAssertGreaterThan(space.width, 0)
        XCTAssertEqual(tab.width, space.width * 2, accuracy: 0.5)   // "a " is two cells; the tab runs to column 4
        XCTAssertGreaterThanOrEqual(tab.minX, space.maxX)
        XCTAssertGreaterThan(marks[0].baseline, space.minY)
        XCTAssertLessThanOrEqual(marks[0].baseline, space.maxY)
    }

    func testNoMarksWithoutSelection() {
        show("a b\tc")
        host.textView.setSelectedRange(NSRange(location: 0, length: 5))
        settle()
        XCTAssertEqual(host.textView.visibleWhitespaceMarks.count, 2)
        host.textView.setSelectedRange(NSRange(location: 2, length: 0))
        settle()
        XCTAssertTrue(host.textView.visibleWhitespaceMarks.isEmpty)
    }

    func testMarksOnSecondLine() {
        show("first\n\tsecond line")
        host.textView.setSelectedRange(NSRange(location: 6, length: 9))
        settle()
        XCTAssertEqual(host.textView.visibleWhitespaceMarks.map(\.kind), [.tab, .space])
        let marks = host.textView.visibleWhitespaceMarks
        XCTAssertGreaterThan(marks[1].rect.minX, marks[0].rect.maxX)
    }

    /// Wrapped lines after the first must not collapse every mark onto the line's left edge.
    func testMarksOnSoftWrappedLine() {
        show(String(repeating: "word ", count: 400))
        host.textView.selectAll(nil)
        settle()
        let marks = host.textView.visibleWhitespaceMarks
        let rows = Dictionary(grouping: marks, by: { $0.rect.minY })
        XCTAssertGreaterThan(rows.count, 3)
        for (_, row) in rows {
            XCTAssertEqual(Set(row.map(\.rect.minX)).count, row.count)
        }
    }

    func testLongUnwrappedLineMarksOnlyVisibleColumns() {
        var settings = EditorSettings()
        settings.wordWrap = false
        let store = BufferTextStore(id: UUID(), text: String(repeating: "x ", count: 200_000), settings: settings)
        host.activate(store, settings: settings)
        host.apply(settings: settings, stores: [store])
        settle()
        host.textView.selectAll(nil)
        settle()
        let marks = host.textView.visibleWhitespaceMarks
        XCTAssertFalse(marks.isEmpty)
        XCTAssertLessThan(marks.count, 5_000)   // 400 000 characters selected; only the visible columns are marked
        let visible = host.textView.visibleRect
        XCTAssertTrue(marks.allSatisfy { $0.rect.maxX > visible.minX && $0.rect.minX < visible.maxX })
    }
}
