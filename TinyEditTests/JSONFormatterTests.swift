import XCTest
@testable import TinyEdit

final class JSONFormatterTests: XCTestCase {
    func fmt(_ s: String, _ sel: NSRange? = nil) -> JSONFormatResult { JSONFormatter.format(text: s, selection: sel) }

    func testPrettyPreservesKeyOrderDuplicatesAndLexemes() {
        guard case .formatted(let out, _) = fmt(#"{"b":1.0,"a":1e2,"b":[true,null,{}],"s":"\u00e9"}"#) else { return XCTFail() }
        XCTAssertEqual(out, """
        {
          "b": 1.0,
          "a": 1e2,
          "b": [
            true,
            null,
            {}
          ],
          "s": "\\u00e9"
        }
        """)
    }

    func testMinify() {
        guard case .formatted(let out, _) = JSONFormatter.minify(text: "{ \"a\" : [ 1 , 2 ] }\n", selection: nil) else { return XCTFail() }
        XCTAssertEqual(out, #"{"a":[1,2]}"#)
    }

    func testAlreadyFormattedIsUnchanged() {
        XCTAssertEqual(fmt("{}"), .unchanged)
        XCTAssertEqual(JSONFormatter.minify(text: "[1,2]", selection: nil), .unchanged)
    }

    func testInvalidReportsRealPosition() {
        XCTAssertEqual(fmt("{\n  \"a\": 1,\n  oops\n}"), .invalid(line: 3, column: 3))
        XCTAssertEqual(fmt("{\"a\":01}"), .invalid(line: 1, column: 7))
        XCTAssertEqual(fmt(""), .invalid(line: 1, column: 1))
    }

    func testSelectionFormatsOnlyCompleteValue() {
        let text = #"x = {"a":1} ;"#
        let ns = text as NSString
        let r = ns.range(of: #"{"a":1}"#)
        guard case .formatted(let out, let range) = fmt(text, NSRange(location: r.location - 1, length: r.length + 2)) else { return XCTFail() }
        XCTAssertEqual(range, r)                       // surrounding whitespace is not touched
        XCTAssertEqual(out, "{\n  \"a\": 1\n}")
        let junk = ns.range(of: "x = {\"a\":1}")
        XCTAssertEqual(fmt(text, junk), .invalid(line: 1, column: 1))
    }

    func testFragmentsAllowed() {
        XCTAssertEqual(fmt("42"), .unchanged)
        XCTAssertEqual(fmt(#""s""#), .unchanged)
    }

    func testUTF8OffsetMapping() {
        let t = "{\n é x"
        XCTAssertNil(JSONFormatter.position(forUTF8Offset: 999, in: t))
        let p = JSONFormatter.position(forUTF8Offset: 5, in: t)   // after "{\n é" (é is 2 bytes)
        XCTAssertEqual(p?.0, 2)
        XCTAssertEqual(p?.1, 3)
    }

    func testDeepNestingDoesNotCrash() {
        let deep = String(repeating: "[", count: 2000) + String(repeating: "]", count: 2000)
        if case .invalid = fmt(deep) {} else { XCTFail() }
    }
}
