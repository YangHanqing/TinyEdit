import XCTest
@testable import TinyEdit

final class TextCleanupTests: XCTestCase {
    func testANSISequences() {
        let colored = "\u{1B}[1;31merror\u{1B}[0m: \u{1B}]8;;https://x.dev\u{1B}\\link\u{1B}]8;;\u{07} \u{1B}(Bdone\u{1B}7"
        XCTAssertEqual(TextCleanup.scan(colored).ansiSequences, 6)
        XCTAssertEqual(TextCleanup.removingANSI(colored), "error: link done")
        XCTAssertEqual(TextCleanup.removingANSI("\u{9B}32mok"), "ok")                    // C1 CSI
    }

    /// An ESC that starts no complete sequence is a stray control character, not a sequence.
    func testIncompleteSequenceIsAStrayControl() {
        let report = TextCleanup.scan("a\u{1B}[31")
        XCTAssertEqual(report.ansiSequences, 0)
        XCTAssertEqual(report.invisible, [.init(value: 0x1B, count: 1)])
        XCTAssertEqual(TextCleanup.removingInvisible("a\u{1B}[31"), "a[31")
        XCTAssertEqual(TextCleanup.removingANSI("\u{1B}]0;title\nnext"), "\u{1B}]0;title\nnext")   // OSC must end on its line
    }

    func testInvisibleCharacters() {
        let text = "pass\u{200B}word \u{202E}txt.exe\u{202C} soft\u{00AD}hyphen\u{FEFF}"
        let report = TextCleanup.scan(text)
        XCTAssertEqual(report.invisible.map(\.value), [0x00AD, 0x200B, 0x202C, 0x202E, 0xFEFF])
        XCTAssertEqual(report.invisibleCount, 5)
        XCTAssertEqual(TextCleanup.removingInvisible(text), "password txt.exe softhyphen")
        XCTAssertEqual(report.invisible[1].label, "U+200B ZERO WIDTH SPACE")
    }

    /// Characters that mean something in some script, and ordinary whitespace, are kept.
    func testMeaningfulCharactersAreKept() {
        let family = "👨\u{200D}👩\u{200D}👧"                    // ZWJ sequence
        let persian = "می\u{200C}خواهم"                         // ZWNJ
        let hebrew = "\u{200F}שלום"                            // RLM
        let england = "🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        let text = [family, persian, hebrew, england, "a\tb\u{0C}c\u{00A0}d\u{3000}e️"].joined(separator: "\n")
        XCTAssertTrue(TextCleanup.scan(text).isEmpty)
        XCTAssertEqual(TextCleanup.removingAll(text), text)
    }

    /// Tag characters outside a flag spell hidden ASCII (prompt smuggling) and are counted as one kind.
    func testTagCharactersOutsideAFlag() {
        let hidden = "hi" + String(String.UnicodeScalarView("ok".unicodeScalars.map { Unicode.Scalar($0.value + 0xE0000)! }))
        let report = TextCleanup.scan(hidden)
        XCTAssertEqual(report.invisible, [.init(value: TextCleanup.tagGroup, count: 2)])
        XCTAssertEqual(TextCleanup.removingAll(hidden), "hi")
    }
}
