import XCTest
@testable import TinyEdit

final class SelectionStatsTests: XCTestCase {
    func testWordsByScript() {
        XCTAssertEqual(SelectionStats.wordCount("Hello, world! It's 2026."), 4)
        XCTAssertEqual(SelectionStats.wordCount("你好，世界。"), 4)                     // each ideograph; punctuation is not a word
        XCTAssertEqual(SelectionStats.wordCount("用 Swift 写 TinyEdit"), 4)
        XCTAssertEqual(SelectionStats.wordCount("ひらがなとカタカナ"), 9)
        XCTAssertEqual(SelectionStats.wordCount("안녕하세요 세계"), 2)                  // Korean uses spaces
        XCTAssertEqual(SelectionStats.wordCount("Grüße, señor"), 2)
        XCTAssertEqual(SelectionStats.wordCount("  \n\t— … "), 0)
    }

    func testCharactersAreGraphemesAndBytesAreUTF8() {
        let stats = SelectionStats(["e\u{301}👨‍👩‍👧中"])
        XCTAssertEqual(stats.characters, 3)
        XCTAssertEqual(stats.utf8Bytes, 3 + 18 + 3)
    }

    /// A range ending right after a line break (whole lines selected) does not touch the next line.
    func testLinesTouched() {
        XCTAssertEqual(SelectionStats(["abc"]).lines, 1)
        XCTAssertEqual(SelectionStats(["a\nb"]).lines, 2)
        XCTAssertEqual(SelectionStats(["a\nb\n"]).lines, 2)
        XCTAssertEqual(SelectionStats(["\n"]).lines, 1)
        XCTAssertEqual(SelectionStats(["a", "b\nc"]), SelectionStats(characters: 4, words: 3, lines: 3, utf8Bytes: 4))
    }
}
