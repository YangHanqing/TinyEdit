import XCTest
@testable import TinyEdit

final class UntitledTitleTests: XCTestCase {
    func testDerivedTitle() {
        XCTAssertNil(EditorBuffer.derivedTitle(fromPrefix: "  \n\t\n"))
        XCTAssertEqual(EditorBuffer.derivedTitle(fromPrefix: "\n\n  hello \t world \nsecond"), "hello world")
        XCTAssertEqual(EditorBuffer.derivedTitle(fromPrefix: String(repeating: "a", count: 40)), String(repeating: "a", count: 18) + "…")
        XCTAssertEqual(EditorBuffer.derivedTitle(fromPrefix: "你好1234567890123445678"), "你好12345678901234…")
    }
}
