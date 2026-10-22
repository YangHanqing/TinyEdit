import XCTest
@testable import TinyEdit

final class LineEditingTests: XCTestCase {
    /// Applies the edits back to front, as the text view does, and returns the text and selection.
    private func run(_ text: String, _ sel: NSRange, _ make: (NSString, NSRange) -> IndentEditing.LineEdits?) -> (String, NSRange)? {
        let ns = NSMutableString(string: text)
        guard let change = make(ns, sel) else { return nil }
        for e in change.edits.reversed() { ns.replaceCharacters(in: e.range, with: e.string) }
        return (ns as String, change.selection)
    }

    private func caret(_ i: Int) -> NSRange { NSRange(location: i, length: 0) }

    func testDuplicate() {
        XCTAssertEqual(run("a\nb\nc", caret(2), LineEditing.duplicate)?.0, "a\nb\nb\nc")
        XCTAssertEqual(run("a\nb\nc", caret(2), LineEditing.duplicate)?.1, caret(4))
        let last = run("a\nbc", caret(3), LineEditing.duplicate)
        XCTAssertEqual(last?.0, "a\nbc\nbc")
        XCTAssertEqual(last?.1, caret(6))
        // Two lines selected, ending at the start of a third: only the two are copied.
        XCTAssertEqual(run("a\nb\nc\n", NSRange(location: 0, length: 4), LineEditing.duplicate)?.0, "a\nb\na\nb\nc\n")
    }

    func testMoveUpAndDown() {
        XCTAssertEqual(run("a\nb\nc", caret(2), LineEditing.moveUp)?.0, "b\na\nc")
        XCTAssertEqual(run("a\nb\nc", caret(2), LineEditing.moveUp)?.1, caret(0))
        XCTAssertEqual(run("a\nb\nc", caret(4), LineEditing.moveUp)?.0, "a\nc\nb")
        XCTAssertNil(run("a\nb", caret(0), LineEditing.moveUp))
        XCTAssertEqual(run("a\nb\nc", caret(2), LineEditing.moveDown)?.0, "a\nc\nb")
        XCTAssertEqual(run("a\nb\nc", caret(2), LineEditing.moveDown)?.1, caret(4))
        XCTAssertEqual(run("a\nb\nc\n", caret(0), LineEditing.moveDown)?.0, "b\na\nc\n")
        XCTAssertNil(run("a\nb", caret(2), LineEditing.moveDown))
        let block = run("1\n2\n3\n4", NSRange(location: 2, length: 3), LineEditing.moveDown)
        XCTAssertEqual(block?.0, "1\n4\n2\n3")
        XCTAssertEqual(block?.1, NSRange(location: 4, length: 3))
    }

    func testDeleteLines() {
        XCTAssertEqual(run("a\nb\nc", caret(2), LineEditing.deleteLines)?.0, "a\nc")
        XCTAssertEqual(run("a\nb\nc", caret(4), LineEditing.deleteLines)?.0, "a\nb")
        XCTAssertEqual(run("a\nb\nc", caret(4), LineEditing.deleteLines)?.1, caret(2))
        XCTAssertEqual(run("only", caret(1), LineEditing.deleteLines)?.0, "")
        XCTAssertNil(run("", caret(0), LineEditing.deleteLines))
    }

    func testJoinLines() {
        let joined = run("foo\n    bar\nbaz", caret(1), LineEditing.joinLines)
        XCTAssertEqual(joined?.0, "foo bar\nbaz")
        XCTAssertEqual(joined?.1, caret(3))
        XCTAssertEqual(run("a\nb\nc\nd", NSRange(location: 0, length: 5), LineEditing.joinLines)?.0, "a b c\nd")
        XCTAssertEqual(run("a \nb", caret(0), LineEditing.joinLines)?.0, "a b")
        XCTAssertEqual(run("a\n\nb", caret(0), LineEditing.joinLines)?.0, "a\nb")
        XCTAssertNil(run("last", caret(0), LineEditing.joinLines))
    }

    func testToggleLineComment() {
        let swift = LineEditing.CommentSyntax.line("//")
        let on = run("  a\n    b\n\n  c", NSRange(location: 0, length: 14)) { LineEditing.toggleComment(in: $0, selection: $1, syntax: swift) }
        XCTAssertEqual(on?.0, "  // a\n  //   b\n\n  // c")
        let off = run(on!.0, NSRange(location: 0, length: (on!.0 as NSString).length)) {
            LineEditing.toggleComment(in: $0, selection: $1, syntax: swift)
        }
        XCTAssertEqual(off?.0, "  a\n    b\n\n  c")
        // Mixed lines are commented, not uncommented.
        XCTAssertEqual(run("# a\nb", NSRange(location: 0, length: 5)) {
            LineEditing.toggleComment(in: $0, selection: $1, syntax: .line("#"))
        }?.0, "# # a\n# b")
        // The caret keeps its place in the text.
        XCTAssertEqual(run("let x", caret(4)) { LineEditing.toggleComment(in: $0, selection: $1, syntax: swift) }?.1, caret(7))
    }

    func testToggleBlockComment() {
        let html = LineEditing.CommentSyntax.block("<!--", "-->")
        let on = run("  <p>hi</p>", caret(3)) { LineEditing.toggleComment(in: $0, selection: $1, syntax: html) }
        XCTAssertEqual(on?.0, "  <!-- <p>hi</p> -->")
        XCTAssertEqual(run(on!.0, caret(3)) { LineEditing.toggleComment(in: $0, selection: $1, syntax: html) }?.0, "  <p>hi</p>")
    }

    func testCommentSyntaxByLanguage() {
        XCTAssertEqual(LineEditing.commentSyntax(for: .swift), .line("//"))
        XCTAssertEqual(LineEditing.commentSyntax(for: .python), .line("#"))
        XCTAssertEqual(LineEditing.commentSyntax(for: .sql), .line("--"))
        XCTAssertEqual(LineEditing.commentSyntax(for: .html), .block("<!--", "-->"))
        XCTAssertEqual(LineEditing.commentSyntax(for: .css), .block("/*", "*/"))
        XCTAssertNil(LineEditing.commentSyntax(for: .plain))
        XCTAssertNil(LineEditing.commentSyntax(for: .json))
        for language in EditorLanguage.allCases where ![.plain, .json, .diff].contains(language) {
            XCTAssertNotNil(LineEditing.commentSyntax(for: language), "\(language)")
        }
    }

    func testSaveCleanup() {
        func clean(_ s: String, trim: Bool = true, final: Bool = true) -> String {
            let ns = NSMutableString(string: s)
            for e in LineEditing.saveCleanup(in: ns, trimTrailingWhitespace: trim, ensureFinalNewline: final).reversed() {
                ns.replaceCharacters(in: e.range, with: e.string)
            }
            return ns as String
        }
        XCTAssertEqual(clean("a  \n\tb\t\n  \nc "), "a\n\tb\n\nc\n")
        XCTAssertEqual(clean("a\n"), "a\n")
        XCTAssertEqual(clean(""), "")
        XCTAssertEqual(clean("a  ", final: false), "a")
        XCTAssertEqual(clean("a  ", trim: false), "a  \n")
        XCTAssertEqual(clean("a\u{3000}\n"), "a\u{3000}\n")   // only spaces and TABs
    }

    func testParseLineTarget() {
        XCTAssertEqual(LineEditing.parseLineTarget("12")?.line, 12)
        XCTAssertNil(LineEditing.parseLineTarget("12")?.column)
        XCTAssertEqual(LineEditing.parseLineTarget(" 3:7 ")?.column, 7)
        XCTAssertEqual(LineEditing.parseLineTarget("3,7")?.column, 7)
        XCTAssertNil(LineEditing.parseLineTarget("0"))
        XCTAssertNil(LineEditing.parseLineTarget("abc"))
        XCTAssertNil(LineEditing.parseLineTarget(""))
    }

    func testBracketMatch() {
        let text = "f(a[1], {b})" as NSString
        XCTAssertEqual(BracketMatcher.match(in: text, caret: 2)?.1, NSRange(location: 11, length: 1))   // after "("
        XCTAssertEqual(BracketMatcher.match(in: text, caret: 12)?.1, NSRange(location: 1, length: 1))   // after ")"
        XCTAssertEqual(BracketMatcher.match(in: text, caret: 8)?.1, NSRange(location: 10, length: 1))   // before "{"
        XCTAssertNil(BracketMatcher.match(in: "a(b" as NSString, caret: 2))
        XCTAssertNil(BracketMatcher.match(in: "abc" as NSString, caret: 1))
    }
}
