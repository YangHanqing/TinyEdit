import XCTest
@testable import TinyEdit

final class TabStripLayoutTests: XCTestCase {
    func testFewTabsStopAtTheMaximumWidth() {
        let layout = TabStripLayout(available: 1000, count: 3, selectedIndex: 0)
        XCTAssertEqual(layout.width, TabStripLayout.maxWidth)
        XCTAssertEqual(layout.selectedWidth, TabStripLayout.maxWidth)
        XCTAssertFalse(layout.overflows(1000))
    }

    func testTabsShareTheWidthBeforeScrolling() {
        // 1000 - 12 padding - 9 gaps of 2 = 970 over 10 tabs.
        let layout = TabStripLayout(available: 1000, count: 10, selectedIndex: 4)
        XCTAssertEqual(layout.width, TabStripLayout.minWidth, "97 is below the minimum")
        XCTAssertTrue(layout.overflows(1000))
        let wide = TabStripLayout(available: 1400, count: 10, selectedIndex: 4)
        XCTAssertEqual(wide.width, 136)   // (1370 - 140) / 9: the selected tab keeps 140
        XCTAssertEqual(wide.selectedWidth, 140)
        let roomy = TabStripLayout(available: 1600, count: 10, selectedIndex: 4)
        XCTAssertEqual(roomy.width, 157)
        XCTAssertEqual(roomy.selectedWidth, 157)
        XCTAssertFalse(roomy.overflows(1600))
    }

    func testManyTabsKeepTheMinimumAndScroll() {
        let layout = TabStripLayout(available: 800, count: 50, selectedIndex: 49)
        XCTAssertEqual(layout.width, TabStripLayout.minWidth)
        XCTAssertEqual(layout.selectedWidth, TabStripLayout.selectedMinWidth)
        XCTAssertTrue(layout.overflows(800))
        XCTAssertEqual(layout.contentWidth, 12 + 49 * 2 + 49 * 100 + 140)
    }

    func testSpansFollowTheWiderSelectedTab() {
        let layout = TabStripLayout(available: 500, count: 6, selectedIndex: 2)
        XCTAssertEqual(layout.span(of: 0), 6...106)
        XCTAssertEqual(layout.span(of: 2), 210...350)
        XCTAssertEqual(layout.span(of: 3), 352...452)
        XCTAssertEqual(layout.span(of: 5).upperBound + TabStripLayout.padding, layout.contentWidth)
    }

    func testRevealScrollsByTheLeastAmount() {
        let layout = TabStripLayout(available: 400, count: 20, selectedIndex: 10)
        // Already visible: no scroll.
        XCTAssertNil(layout.offset(revealing: 1, from: 0, viewport: 400))
        // To the right: its trailing edge stops the reveal margin inside the viewport's.
        let span = layout.span(of: 10)
        XCTAssertEqual(layout.offset(revealing: 10, from: 0, viewport: 400), span.upperBound + 24 - 400)
        // To the left: likewise at the leading edge.
        XCTAssertEqual(layout.offset(revealing: 3, from: 1000, viewport: 400), layout.span(of: 3).lowerBound - 24)
        // Visible but under the fade still scrolls.
        XCTAssertNotNil(layout.offset(revealing: 3, from: layout.span(of: 3).lowerBound - 10, viewport: 400))
        // The first and last tabs scroll to the ends exactly.
        XCTAssertEqual(layout.offset(revealing: 0, from: 500, viewport: 400), 0)
        XCTAssertEqual(layout.offset(revealing: 19, from: 0, viewport: 400), layout.contentWidth - 400)
        XCTAssertNil(layout.offset(revealing: 20, from: 0, viewport: 400))
    }

    func testOffsetsAreClampedToTheContent() {
        let layout = TabStripLayout(available: 400, count: 20, selectedIndex: nil)
        XCTAssertEqual(layout.clampOffset(-30, viewport: 400), 0)
        XCTAssertEqual(layout.clampOffset(1e6, viewport: 400), layout.contentWidth - 400)
        XCTAssertEqual(TabStripLayout(available: 1000, count: 2, selectedIndex: 0).clampOffset(50, viewport: 1000), 0)
    }

    func testMenuTitlesNameTheDirectoryOnlyForDuplicates() {
        var a = EditorBuffer(title: "notes.txt")
        a.fileBookmark = Data([1])
        a.directoryPath = "/Users/me/work"
        var b = EditorBuffer(title: "notes.txt")
        b.fileBookmark = Data([2])
        b.directoryPath = "/tmp"
        b.dirty = true
        var c = EditorBuffer(title: "todo.md")
        c.fileBookmark = Data([3])
        c.directoryPath = "/tmp"
        c.conflict = .missing
        let titles = TabMenuTitles.make([a, b, c], home: "/Users/me")
        XCTAssertEqual(titles[a.id], "notes.txt — ~/work")
        XCTAssertEqual(titles[b.id], "notes.txt — /tmp  •")
        XCTAssertEqual(titles[c.id], "⚠︎ todo.md")
    }
}
