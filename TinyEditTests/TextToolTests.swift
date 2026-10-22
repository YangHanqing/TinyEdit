import XCTest
@testable import TinyEdit

final class TextToolTests: XCTestCase {
    private func apply(_ tool: TextTool, _ s: String) throws -> String {
        try TextTransform.apply(tool, to: s, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    }

    private func assertError(_ tool: TextTool, _ s: String, _ message: String, line: UInt = #line) {
        XCTAssertThrowsError(try apply(tool, s), line: line) { XCTAssertEqual($0 as? TextToolError, TextToolError(message: message), line: line) }
    }

    func testJSONStringRoundTrip() throws {
        XCTAssertEqual(try apply(.unescapeJSONString, #""{\"a\":\"中\\n\"}""#), #"{"a":"中\n"}"#)
        XCTAssertEqual(try apply(.unescapeJSONString, #"{\"a\":1}"#), #"{"a":1}"#)   // bare, as copied from a log
        XCTAssertEqual(try apply(.escapeJSONString, #"{"u":"a/b"}"#), #""{\"u\":\"a/b\"}""#)
        assertError(.unescapeJSONString, #"a"b"#, "Not a valid JSON string")
    }

    func testBase64() throws {
        XCTAssertEqual(try apply(.base64Encode, "你好 TinyEdit"), "5L2g5aW9IFRpbnlFZGl0")
        XCTAssertEqual(try apply(.base64Decode, "5L2g5aW9IFRp\nbnlFZGl0"), "你好 TinyEdit")
        XCTAssertEqual(try apply(.base64Decode, "eyJhIjoxfQ"), #"{"a":1}"#)       // URL-safe, unpadded
        assertError(.base64Decode, "!!!", "Invalid Base64")
        assertError(.base64Decode, "/w==", "Decoded Base64 is not UTF-8 text")
    }

    func testURL() throws {
        XCTAssertEqual(try apply(.urlEncode, "a b&c=中/~"), "a%20b%26c%3D%E4%B8%AD%2F~")
        XCTAssertEqual(try apply(.urlDecode, "a%20b%26c%3D%E4%B8%AD"), "a b&c=中")
        assertError(.urlDecode, "%E4%B8", "Invalid percent-encoding")
    }

    func testUnescapeUnicode() throws {
        XCTAssertEqual(try apply(.unescapeUnicode, #"{"n":"中文","e":"😀"}"#), #"{"n":"中文","e":"😀"}"#)
        XCTAssertEqual(try apply(.unescapeUnicode, #"\u12 and \x41 and \"#), #"\u12 and \x41 and \"#)
    }

    func testSortAndReverseLines() throws {
        XCTAssertEqual(try apply(.sortLinesAscending, "b10\nB1\na\nb2\n"), "a\nB1\nb2\nb10\n")   // final break stays last
        XCTAssertEqual(try apply(.sortLinesDescending, "b10\nB1\na\nb2"), "b10\nb2\nB1\na")
        XCTAssertEqual(try apply(.sortLinesAscending, "B\nb\nB\nb"), "b\nb\nB\nB")                // case decides the same way every time
        XCTAssertEqual(try apply(.reverseLines, "1\n2\n3\n"), "3\n2\n1\n")
        let shuffled = try apply(.shuffleLines, "1\n2\n3\n4\n5\n")
        XCTAssertTrue(shuffled.hasSuffix("\n"))
        XCTAssertEqual(shuffled.split(separator: "\n").sorted(), ["1", "2", "3", "4", "5"])
    }

    func testRemoveLines() throws {
        XCTAssertEqual(try apply(.removeDuplicateLines, "b\na\nb\n\nA\n\na\n"), "b\na\n\nA\n")   // first kept, order kept
        XCTAssertEqual(try apply(.removeBlankLines, "a\n\n \t\nb\n\u{3000}\n"), "a\nb\n")
        XCTAssertEqual(try apply(.trimTrailingWhitespace, "a  \n\tb\t\nc\u{3000}\n"), "a\n\tb\nc\n")
    }

    func testLineRangeCoversWholeLines() {
        let text = "ab\ncd\nef" as NSString
        XCTAssertEqual(TextTransform.lineRange(covering: NSRange(location: 1, length: 3), in: text), NSRange(location: 0, length: 6))
        XCTAssertEqual(TextTransform.lineRange(covering: NSRange(location: 0, length: 6), in: text), NSRange(location: 0, length: 6))
        XCTAssertEqual(TextTransform.lineRange(covering: NSRange(location: 7, length: 0), in: text), NSRange(location: 6, length: 2))
    }

    func testCleanupTools() throws {
        XCTAssertEqual(try apply(.removeANSIEscapes, "\u{1B}[32mok\u{1B}[0m\u{200B}"), "ok\u{200B}")
        XCTAssertEqual(try apply(.removeInvisibleCharacters, "\u{1B}[32mok\u{200B}"), "\u{1B}[32mok")
    }

    func testDecodeJWT() throws {
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjMiLCJleHAiOjE3MDAwMDAwMDB9.sig"
        let expected = """
        {
          "header": {
            "alg": "HS256",
            "typ": "JWT"
          },
          "payload": {
            "sub": "123",
            "exp": 1700000000
          }
        }
        """
        XCTAssertEqual(try apply(.decodeJWT, token), expected)
        XCTAssertEqual(try apply(.decodeJWT, "Bearer " + token), expected)
        assertError(.decodeJWT, "abc", "Not a JWT")
        assertError(.decodeJWT, "abc.def.ghi", "Not a JWT")
    }

    func testTimestampUnitsByMagnitude() throws {
        XCTAssertEqual(try apply(.timestampToDate, "1700000000"), "2023-11-15T06:13:20+08:00")
        XCTAssertEqual(try apply(.timestampToDate, "1700000000123"), "2023-11-15T06:13:20.123+08:00")
        XCTAssertEqual(try apply(.timestampToDate, "1700000000123456"), "2023-11-15T06:13:20.123+08:00")
        assertError(.timestampToDate, "17e8", "Not a Unix timestamp")
    }

    func testPaletteFilter() {
        let commands = TextTool.allCases.map {
            PaletteCommand(id: $0.id, title: $0.title, englishTitle: $0.englishTitle, keywords: $0.keywords) {}
        }
        XCTAssertEqual(PaletteCommand.filter(commands, query: "").count, TextTool.allCases.count)
        XCTAssertEqual(PaletteCommand.filter(commands, query: "url dec").map(\.id), ["urlDecode"])
        XCTAssertEqual(PaletteCommand.filter(commands, query: "epoch").map(\.id), ["timestampToDate"])
        // Hits whose title starts with the first word sort first.
        XCTAssertEqual(PaletteCommand.filter(commands, query: "decode").map(\.id), ["decodeJWT", "base64Decode", "urlDecode"])
        XCTAssertEqual(PaletteCommand.filter(commands, query: "unescape").map(\.id), ["unescapeJSONString", "unescapeUnicode"])
        XCTAssertEqual(PaletteCommand.filter(commands, query: "clean").map(\.id), TextToolGroup.cleanup.tools.map(\.id))
    }

    /// The Tools submenus list every tool once, in `allCases` order.
    func testGroupsCoverEveryTool() {
        XCTAssertEqual(TextToolGroup.allCases.flatMap(\.tools), TextTool.allCases)
        XCTAssertTrue(TextToolGroup.allCases.allSatisfy { !$0.tools.isEmpty && !$0.tools[0].startsSubsection })
    }
}
