import XCTest
@testable import TinyEdit

final class HighlighterTests: XCTestCase {
    func kinds(_ lang: EditorLanguage, _ text: String) -> [(String, TokenKind)] {
        let ns = text as NSString
        return SyntaxHighlighter.spans(language: lang, text: text, limit: nil).map { (ns.substring(with: $0.range), $0.kind) }
    }

    func testJSON() {
        let k = kinds(.json, #"{"a": [1, -2.5e3, true, false, null]}"#)
        XCTAssertEqual(k.map(\.0), [#""a""#, "1", "-2.5e3", "true", "false", "null"])
        XCTAssertEqual(k.map(\.1), [.string, .number, .number, .boolean, .boolean, .null])
    }

    func testPython() {
        let src = "def f(x):  # note\n    s = f'a#b' + \"q\"\n    return None if x else True\n"
        let k = kinds(.python, src)
        XCTAssertTrue(k.contains { $0.0 == "def" && $0.1 == .keyword })
        XCTAssertTrue(k.contains { $0.0 == "# note" && $0.1 == .comment })
        XCTAssertTrue(k.contains { $0.0 == "f'a#b'" && $0.1 == .string })   // # inside string is not a comment
        XCTAssertTrue(k.contains { $0.0 == "None" && $0.1 == .null })
        XCTAssertTrue(k.contains { $0.0 == "True" && $0.1 == .boolean })
    }

    func testPythonTripleQuoteAndNumbers() {
        let k = kinds(.python, "x = \"\"\"a\nb\"\"\"\ny = 3.14\n")
        XCTAssertTrue(k.contains { $0.0 == "\"\"\"a\nb\"\"\"" && $0.1 == .string })
        XCTAssertTrue(k.contains { $0.0 == "3.14" && $0.1 == .number })
    }

    func testMarkdown() {
        let src = "# Title\ntext `code` more\n```\n# not heading\n```\n"
        let k = kinds(.markdown, src)
        XCTAssertEqual(k.first?.0, "# Title")
        XCTAssertEqual(k.first?.1, .heading)
        XCTAssertTrue(k.contains { $0.0 == "`code`" && $0.1 == .code })
        XCTAssertFalse(k.contains { $0.0 == "# not heading" && $0.1 == .heading })
        XCTAssertTrue(k.contains { $0.0 == "# not heading" && $0.1 == .code })
    }

    func testLimitOffsetsRanges() {
        let text = "aaa\n{\"k\": 1}\n"
        let spans = SyntaxHighlighter.spans(language: .json, text: text, limit: NSRange(location: 4, length: 8))
        XCTAssertEqual((text as NSString).substring(with: spans[0].range), "\"k\"")
    }

    func testDetectionAndGenericLanguages() {
        XCTAssertEqual(EditorLanguage.detect(fileName: "Main.java", text: ""), .java)
        XCTAssertEqual(EditorLanguage.detect(fileName: "Makefile", text: ""), .makefile)
        XCTAssertEqual(EditorLanguage.detect(fileName: "run", text: "#!/usr/bin/env python3\nx"), .python)
        XCTAssertEqual(EditorLanguage.detect(fileName: "notes.txt", text: ""), .plain)
        let go = kinds(.go, "func main() { s := `a\nb` // hi\n}")
        XCTAssertTrue(go.contains { $0.0 == "func" && $0.1 == .keyword })
        XCTAssertTrue(go.contains { $0.0 == "`a\nb`" && $0.1 == .string })
        XCTAssertTrue(go.contains { $0.0 == "// hi" && $0.1 == .comment })
        let c = kinds(.c, "#include <x.h>\nint a = 0x1F; /* c */")
        XCTAssertTrue(c.contains { $0.0 == "#include <x.h>" && $0.1 == .preprocessor })
        XCTAssertTrue(c.contains { $0.0 == "0x1F" && $0.1 == .number })
        let sh = kinds(.shell, "echo $# # real\nif [ -n \"$x\" ]; then")
        XCTAssertTrue(sh.contains { $0.0 == "# real" && $0.1 == .comment })
        XCTAssertFalse(sh.contains { $0.1 == .comment && $0.0.hasPrefix("$") })
        let y = kinds(.yaml, "name: x\n- k: true # c\n")
        XCTAssertTrue(y.contains { $0.0 == "name" && $0.1 == .key })
        XCTAssertTrue(y.contains { $0.0 == "k" && $0.1 == .key })
        let h = kinds(.html, "<a href=\"u\">x</a><!-- c -->")
        XCTAssertTrue(h.contains { $0.0 == "a" && $0.1 == .tag })
        XCTAssertTrue(h.contains { $0.0 == "href" && $0.1 == .attribute })
        XCTAssertTrue(h.contains { $0.0 == "<!-- c -->" && $0.1 == .comment })
        let rs = kinds(.rust, "fn f<'a>(x: &'a str) { let c = 'x'; }")
        XCTAssertTrue(rs.contains { $0.0 == "'x'" && $0.1 == .string })
        XCTAssertFalse(rs.contains { $0.0.hasPrefix("'a") })
        for lang in EditorLanguage.allCases { _ = SyntaxHighlighter.spans(language: lang, text: "a \"b 'c\n/* d", limit: nil) }
    }

    func testGenericScanSpeedOnTwoMegabytes() {
        let line = "public static void main(String[] args) { int x = 42; // note \"s\" }\n"
        let text = String(repeating: line, count: 2_000_000 / line.utf8.count)
        let start = Date()
        let spans = SyntaxHighlighter.spans(language: .java, text: text, limit: nil)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(spans.isEmpty)
        XCTAssertLessThan(elapsed, 3.0, "Debug build scan of 2 MB took \(elapsed)s")
        print("generic scan 2MB:", elapsed)
    }

    func testExtensionMap() {
        XCTAssertEqual(EditorLanguage.from(fileExtension: "MD"), .markdown)
        XCTAssertEqual(EditorLanguage.from(fileExtension: "py"), .python)
        XCTAssertEqual(EditorLanguage.from(fileExtension: ""), .plain)
    }
}
