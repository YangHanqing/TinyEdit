import XCTest
@testable import TinyEdit

final class MarkdownTableLayoutTests: XCTestCase {
    func testColumnsThatFitKeepTheirOneLineWidth() {
        XCTAssertEqual(MarkdownTableLayout.widths(natural: [50, 80.2], available: 300), [50, 81])
    }

    func testNarrowColumnsKeepTheirWidthAndWideOnesShareTheRest() {
        // 40 + 60 + 2 × 250 = 600: both wide columns wrap at the same width.
        XCTAssertEqual(MarkdownTableLayout.widths(natural: [40, 60, 1000, 500], available: 600), [40, 60, 250, 250])
        XCTAssertEqual(MarkdownTableLayout.widths(natural: [40, 2000], available: 500), [40, 460])
    }

    func testAWideColumnThatFitsDuringTheShareStopsAtItsWidth() {
        XCTAssertEqual(MarkdownTableLayout.widths(natural: [100, 300, 2000], available: 900), [100, 300, 500])
    }

    func testWrappingColumnsNeverGoBelowTheMinimum() {
        let widths = MarkdownTableLayout.widths(natural: [200, 2000], available: 150)
        XCTAssertEqual(widths, [MarkdownTableLayout.minColumnWidth, MarkdownTableLayout.minColumnWidth])
        XCTAssertEqual(MarkdownTableLayout.widths(natural: [30, 2000], available: 100), [30, 96])
    }

    func testTheResultNeverExceedsTheAvailableWidthWhenItCanFit() {
        let natural: [CGFloat] = [37.4, 812.9, 133.3, 2048.1, 96.5]
        for available in stride(from: CGFloat(500), through: 3100, by: 37) {
            let widths = MarkdownTableLayout.widths(natural: natural, available: available)
            XCTAssertLessThanOrEqual(widths.reduce(0, +), available)
            XCTAssertGreaterThan(widths.reduce(0, +), available - CGFloat(natural.count))
        }
    }

    func testEmptyTable() {
        XCTAssertEqual(MarkdownTableLayout.widths(natural: [], available: 400), [])
    }
}
