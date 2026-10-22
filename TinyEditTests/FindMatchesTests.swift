import XCTest
@testable import TinyEdit

final class FindMatchesTests: XCTestCase {
    func testRangesAreNonOverlappingAndRespectCase() {
        let text = "aaa Aa" as NSString
        XCTAssertEqual(FindMatches.ranges(of: "aa", in: text, caseSensitive: true).ranges,
                       [NSRange(location: 0, length: 2)])
        XCTAssertEqual(FindMatches.ranges(of: "aa", in: text, caseSensitive: false).ranges,
                       [NSRange(location: 0, length: 2), NSRange(location: 4, length: 2)])
        XCTAssertEqual(FindMatches.ranges(of: "", in: text, caseSensitive: false).ranges, [])
    }

    func testCountingStopsAtTheLimit() {
        let (ranges, capped) = FindMatches.ranges(of: "x", in: "xxxxx" as NSString, caseSensitive: true, limit: 3)
        XCTAssertEqual(ranges.count, 3)
        XCTAssertTrue(capped)
        XCTAssertFalse(FindMatches.ranges(of: "x", in: "xxx" as NSString, caseSensitive: true, limit: 3).capped)
    }

    func testIndexLookups() {
        let ranges = [NSRange(location: 0, length: 2), NSRange(location: 5, length: 2), NSRange(location: 9, length: 2)]
        XCTAssertEqual(FindMatches.index(of: NSRange(location: 5, length: 2), in: ranges), 1)
        XCTAssertNil(FindMatches.index(of: NSRange(location: 5, length: 0), in: ranges))
        XCTAssertEqual(FindMatches.firstIndex(atOrAfter: 3, in: ranges), 1)
        XCTAssertEqual(FindMatches.firstIndex(atOrAfter: 10, in: ranges), 0)
        XCTAssertNil(FindMatches.firstIndex(atOrAfter: 0, in: []))
    }
}
