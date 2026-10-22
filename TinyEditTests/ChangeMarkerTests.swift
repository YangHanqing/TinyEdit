import XCTest
@testable import TinyEdit

final class ChangeMarkerTests: XCTestCase {
    private func r(_ loc: Int, _ len: Int) -> NSRange { NSRange(location: loc, length: len) }

    // MARK: Diff

    func testIdenticalTextHasNoChanges() {
        let c = LineDiff.changes(from: "a\nb\n", to: "a\nb\n")
        XCTAssertEqual(c, LineChanges(markers: [], added: 0, removed: 0))
        XCTAssertNil(c?.summary)
    }

    func testAddedModifiedDeleted() throws {
        // old: a b c d e   new: a B c x d   (b changed, x added, e removed)
        let c = try XCTUnwrap(LineDiff.changes(from: "a\nb\nc\nd\ne\n", to: "a\nB\nc\nx\nd\n"))
        XCTAssertEqual(c.markers, [
            ChangeMarker(kind: .modified, range: r(2, 2)),
            ChangeMarker(kind: .added, range: r(6, 2)),
            ChangeMarker(kind: .deleted, range: r(10, 0)),   // end of document: e was below d
        ])
        XCTAssertEqual(c.added, 2)
        XCTAssertEqual(c.removed, 2)
        XCTAssertEqual(c.summary, "+2 −2")
    }

    func testDeletedInMiddleAnchorsToLineBelow() throws {
        let c = try XCTUnwrap(LineDiff.changes(from: "a\nb\nc", to: "a\nc"))
        XCTAssertEqual(c.markers, [ChangeMarker(kind: .deleted, range: r(2, 0))])
    }

    func testLastLineWithoutNewline() throws {
        let c = try XCTUnwrap(LineDiff.changes(from: "a", to: "a\nb"))
        XCTAssertEqual(c.markers, [ChangeMarker(kind: .added, range: r(2, 1))])
    }

    func testUTF16Offsets() throws {
        let c = try XCTUnwrap(LineDiff.changes(from: "😀\nb", to: "😀\nB"))
        XCTAssertEqual(c.markers, [ChangeMarker(kind: .modified, range: r(3, 1))])
    }

    func testTooManyEditsFallsBackToOneRun() throws {
        let old = (0..<50).map { "o\($0)" }.joined(separator: "\n")
        let new = (0..<50).map { "n\($0)" }.joined(separator: "\n")
        let c = try XCTUnwrap(LineDiff.changes(from: "top\n" + old + "\nend", to: "top\n" + new + "\nend", maxEdits: 10))
        XCTAssertEqual(c.markers.count, 1)
        XCTAssertEqual(c.markers.first?.kind, .modified)
        XCTAssertEqual(c.markers.first?.range.location, 4)
        XCTAssertEqual(c.added, 50)
        XCTAssertEqual(c.removed, 50)
    }

    func testMyersMatchesBruteForceLengths() {
        // The script length must equal n + m - 2 * LCS.
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let a = (0..<Int.random(in: 0...12, using: &rng)).map { _ in Int.random(in: 0...3, using: &rng) }
            let b = (0..<Int.random(in: 0...12, using: &rng)).map { _ in Int.random(in: 0...3, using: &rng) }
            let hunks = LineDiff.myers(a, b, maxEdits: 100)!
            let edits = hunks.reduce(0) { $0 + $1.inserted + $1.removed }
            XCTAssertEqual(edits, a.count + b.count - 2 * lcs(a, b), "\(a) \(b)")
            // Applying the hunks to a must give b's length.
            XCTAssertEqual(a.count + hunks.reduce(0) { $0 + $1.inserted - $1.removed }, b.count)
        }
    }

    private func lcs(_ a: [Int], _ b: [Int]) -> Int {
        var t = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0..<a.count {
            for j in 0..<b.count {
                t[i + 1][j + 1] = a[i] == b[j] ? t[i][j] + 1 : max(t[i][j + 1], t[i + 1][j])
            }
        }
        return t[a.count][b.count]
    }

    // MARK: Adjusting through edits

    private let markers = [
        ChangeMarker(kind: .modified, range: NSRange(location: 2, length: 2)),
        ChangeMarker(kind: .deleted, range: NSRange(location: 6, length: 0)),
        ChangeMarker(kind: .added, range: NSRange(location: 8, length: 4)),
    ]

    func testInsertBeforeShiftsEverything() {
        let out = ChangeMarker.adjusting(markers, editedRange: r(0, 3), delta: 3)
        XCTAssertEqual(out.map(\.range), [r(5, 2), r(9, 0), r(11, 4)])
    }

    func testTypingInsideAMarkerGrowsIt() {
        let out = ChangeMarker.adjusting(markers, editedRange: r(9, 2), delta: 2)
        XCTAssertEqual(out.map(\.range), [r(2, 2), r(6, 0), r(8, 6)])
    }

    func testTypingAtMarkerStartJoinsIt() {
        let out = ChangeMarker.adjusting(markers, editedRange: r(2, 1), delta: 1)
        XCTAssertEqual(out[0].range, r(2, 3))
    }

    func testInsertAtMarkerEndStaysOutside() {
        let out = ChangeMarker.adjusting(markers, editedRange: r(4, 1), delta: 1)
        XCTAssertEqual(out[0].range, r(2, 2))
        XCTAssertEqual(out[1].range, r(7, 0))
    }

    func testReplacingAllDropsMarkers() {
        XCTAssertEqual(ChangeMarker.adjusting(markers, editedRange: r(0, 30), delta: 30 - 12), [])
    }

    func testDeletingAMarkedLineDropsIt() {
        let out = ChangeMarker.adjusting(markers, editedRange: r(2, 0), delta: -2)
        XCTAssertEqual(out, [ChangeMarker(kind: .deleted, range: r(4, 0)), ChangeMarker(kind: .added, range: r(6, 4))])
    }

    // MARK: Gutter lookup

    func testGutterHit() {
        XCTAssertEqual(markers.gutterHit(paragraph: r(0, 2), documentLength: 12), .init())
        XCTAssertEqual(markers.gutterHit(paragraph: r(2, 2), documentLength: 12), .init(bar: .modified))
        XCTAssertEqual(markers.gutterHit(paragraph: r(6, 2), documentLength: 12), .init(deletedAbove: true))
        XCTAssertEqual(markers.gutterHit(paragraph: r(10, 2), documentLength: 12), .init(bar: .added))   // wrapped line inside a run
        let atEnd = [ChangeMarker(kind: .deleted, range: r(4, 0))]
        XCTAssertEqual(atEnd.gutterHit(paragraph: r(2, 2), documentLength: 4), .init(deletedBelow: true))
    }
}
