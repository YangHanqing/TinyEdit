import XCTest
@testable import TinyEdit

final class LineEndingTests: XCTestCase {
    func testDetect() {
        XCTAssertEqual(LineEnding.detect("a\nb\n"), .lf)
        XCTAssertEqual(LineEnding.detect("a\r\nb\r\n"), .crlf)
        XCTAssertEqual(LineEnding.detect("a\r\nb\n"), .lf)          // tie -> LF
        XCTAssertEqual(LineEnding.detect("a\r\nb\r\nc\n"), .crlf)   // more CRLF -> CRLF
        XCTAssertEqual(LineEnding.detect("a\rb\rc"), .lf)           // bare CR -> LF
        XCTAssertEqual(LineEnding.detect(""), .lf)
    }
    func testNormalize() {
        XCTAssertEqual(LineEnding.normalizeToLF("a\r\nb\rc\nd"), "a\nb\nc\nd")
        XCTAssertEqual(LineEnding.normalizeToLF("plain"), "plain")
    }
    func testApplyOnlyAtSave() {
        XCTAssertEqual(LineEnding.apply("a\nb", ending: .crlf), "a\r\nb")
        XCTAssertEqual(LineEnding.apply("a\nb", ending: .lf), "a\nb")
    }
    func testApplyFoldsStrayCRBeforeConverting() {
        XCTAssertEqual(LineEnding.apply("a\r\nb\rc", ending: .crlf), "a\r\nb\r\nc")   // never "\r\r\n"
        XCTAssertEqual(LineEnding.apply("a\r\nb", ending: .lf), "a\nb")
    }
}
