import XCTest
@testable import TinyEdit

final class JSONLocatorTests: XCTestCase {
    /// The member at the caret placed where `|` is in `marked` (the marker is removed).
    private func member(_ marked: String) -> (JSONMember?, [UInt16]) {
        let offset = (marked as NSString).range(of: "|").location
        let text = marked.replacingOccurrences(of: "|", with: "")
        let u = Array(text.utf16)
        return (JSONLocator.member(around: NSRange(location: offset, length: 0), in: u), u)
    }

    private func value(_ marked: String) -> String? {
        let (m, u) = member(marked)
        return m.map { JSONLocator.valueText($0, in: u) }
    }

    func testCaretOnKeyOrValueFindsThePair() {
        XCTAssertEqual(member(#"{"na|me": "Ada", "age": 36}"#).0?.key, "name")
        XCTAssertEqual(member(#"{"name"|: "Ada", "age": 36}"#).0?.key, "name")
        XCTAssertEqual(member(#"{"name": "A|da", "age": 36}"#).0?.key, "name")
        XCTAssertEqual(member(#"{"name": "Ada"|, "age": 36}"#).0?.key, "name")   // right after the value
        XCTAssertEqual(member(#"{"name": "Ada", |"age": 36}"#).0?.key, "age")    // right before the key
        XCTAssertEqual(member(#"{"name": "Ada", "age": 3|6}"#).0?.kind, .scalar)
        XCTAssertNil(member(#"{"name": "Ada",| "age": 36}"#).0)                 // between members of the top level
        XCTAssertNil(member(#"|{"a": 1}"#).0)                                     // the top-level value itself
    }

    func testInnermostMemberAndPath() {
        let doc = #"{"data": {"items": [{"id": 7}, {"id": 8, "tags": ["x", "y|"]}]}}"#
        let m = member(doc).0
        XCTAssertEqual(m?.path, [.key("data"), .key("items"), .index(1), .key("tags"), .index(1)])
        XCTAssertEqual(m?.pathText, "data.items[1].tags[1]")
        XCTAssertEqual(m?.shortName, "tags[1]")
        XCTAssertNil(m?.key)
        XCTAssertEqual(member(#"{"data": {"it|ems": []}}"#).0?.pathText, "data.items")
        // Inside an object's whitespace: the object's own pair.
        XCTAssertEqual(member("{\"a\": {\n  |\n  \"b\": 1\n}}").0?.key, "a")
        XCTAssertEqual(member(#"{"a b": {"c.d": |1}}"#).0?.pathText, #"["a b"]["c.d"]"#)
        XCTAssertEqual(member(#"{"名前": |1}"#).0?.pathText, "名前")
        XCTAssertEqual(member(#"[[1], [|2]]"#).0?.pathText, "[1][0]")
    }

    func testStringValuesAreDecoded() {
        XCTAssertEqual(value(#"{"s": "a|\nb \"q\" 中 😀 \/"}"#), "a\nb \"q\" 中 😀 /")
        XCTAssertEqual(value(#"{"s": "bad \x|"}"#), #""bad \x""#)                 // a bad escape copies as written
        XCTAssertEqual(member(#"{"k\"ey": |1}"#).0?.key, "k\"ey")
    }

    func testScalarsCopyAsWritten() {
        XCTAssertEqual(value(#"{"n": 1.50|0e3}"#), "1.500e3")
        XCTAssertEqual(value(#"{"b": tr|ue}"#), "true")
        XCTAssertEqual(value(#"{"z": nu|ll}"#), "null")
    }

    func testContainersAreMovedLeft() {
        let doc = """
        {
          "obj|": {
            "x": [
              1
            ]
          }
        }
        """
        XCTAssertEqual(value(doc), "{\n  \"x\": [\n    1\n  ]\n}")
        XCTAssertEqual(member(doc).0?.kind, .object)
        XCTAssertEqual(value("{\"a\": [1,\n2]|}"), "[1,\n2]")
    }

    func testSelectionMustFitInsideOneMember() {
        let text = #"{"a": "hello", "b": 2}"#
        let u = Array(text.utf16)
        XCTAssertEqual(JSONLocator.member(around: NSRange(location: 8, length: 3), in: u)?.key, "a")
        XCTAssertNil(JSONLocator.member(around: NSRange(location: 8, length: 10), in: u))   // spans a and b
    }

    func testToleratesUnfinishedAndLooseJSON() {
        XCTAssertEqual(member("{\"a\": {\"b\": tr|").0?.pathText, "a.b")            // unclosed
        XCTAssertEqual(value("{\"a|\": [1, 2"), "[1, 2")
        XCTAssertEqual(value("{\"a\": [1, 2|"), "2")
        XCTAssertEqual(member("{\n  // note: \"x\"\n  \"a\": |1 /* c */\n}").0?.key, "a")
        XCTAssertEqual(member("{a: |1}").0?.key, "a")                                 // JSON5 unquoted key
        XCTAssertEqual(member("{\"a\": 1}\n{\"b\": |2}").0?.pathText, "b")           // JSON Lines
        XCTAssertNil(member("").0)
        XCTAssertNil(member("plain |text").0)
    }

    func testOpenedTextFormatsJSONStrings() {
        XCTAssertEqual(AppState.openedText(#"{"a":1}"#, kind: .string).0, "{\n  \"a\": 1\n}")
        XCTAssertTrue(AppState.openedText(#"{"a":1}"#, kind: .string).isJSON)
        XCTAssertFalse(AppState.openedText("{not json", kind: .string).isJSON)
        XCTAssertFalse(AppState.openedText("hello", kind: .string).isJSON)
        XCTAssertTrue(AppState.openedText("[1]", kind: .array).isJSON)
    }

    func testValueMarksIncludeThePicturesPreviewWouldShow() {
        let doc = #"""
        {"avatar": "https://cdn.test/u/1", "home": "https://x.test/", "list": ["https://x.test/a.PNG", "b"],
         "icon": "data:image/png;base64,AAAA", "text": "data:text/plain,hi", "logo": "h\u0074tps://x.test/l",
         "nested": {"thumbnailUrl": "https://x.test/t?s=1"}, "escaped": "https:\/\/x.test\/e.jpg"}
        """#
        let u = Array(doc.utf16)
        let marks = JSONLocator.valueMarks(in: u)
        let ns = doc as NSString
        func range(_ value: String) -> NSRange { ns.range(of: "\"" + value + "\"") }
        XCTAssertEqual(marks, [
            JSONValueMark(valueRange: range("https://cdn.test/u/1"), kind: .image(.remote)),       // image-like key
            JSONValueMark(valueRange: range("https://x.test/"), kind: .link(URL(string: "https://x.test/")!)),
            JSONValueMark(valueRange: range("https://x.test/a.PNG"), kind: .image(.remote)),       // extension, in an array
            JSONValueMark(valueRange: range("data:image/png;base64,AAAA"), kind: .image(.inline)),
            JSONValueMark(valueRange: range(#"h\u0074tps://x.test/l"#), kind: .image(.remote)),
            JSONValueMark(valueRange: range("https://x.test/t?s=1"), kind: .image(.remote)),
            JSONValueMark(valueRange: range("https:\\/\\/x.test\\/e.jpg"), kind: .image(.remote)),  // escapes decoded
        ])
        // Each is the member a caret inside it finds, with the same picture or link.
        for mark in marks.dropFirst() {
            let m = JSONLocator.member(around: NSRange(location: mark.valueRange.location + 1, length: 0), in: u)
            XCTAssertEqual(m?.valueRange, mark.valueRange)
            let insight = m.map { JSONValueInsight($0, in: u) }
            switch mark.kind {
            case .image(let source): XCTAssertEqual(insight?.image, source)
            case .link(let url): XCTAssertEqual(insight?.link, url); XCTAssertNil(insight?.image)
            default: XCTFail("unexpected \(mark.kind)")
            }
        }
        XCTAssertEqual(JSONLocator.valueMarks(in: u, limit: 2).count, 2)
        XCTAssertEqual(JSONLocator.valueMarks(in: Array(#""https://x.test/a.png""#.utf16)), [])   // top level is not a member
    }

    func testValueMarksIncludeColorsAndTimes() throws {
        let doc = #"""
        {"fg": "#FF8800", "bg": "rgb(0, 128, 255)", "tag": "#cafe1", "name": "red", "n": 42,
         "created": 1700000000, "ms": "1700000000123", "id": 12345678901, "old": 123456789,
         "flags": [true, null]}
        """#
        let u = Array(doc.utf16)
        let ns = doc as NSString
        func range(_ value: String) -> NSRange { ns.range(of: value) }
        XCTAssertEqual(JSONLocator.valueMarks(in: u), [
            JSONValueMark(valueRange: range(##""#FF8800""##), kind: .color(JSONColor(red: 1, green: 136.0 / 255, blue: 0, alpha: 1))),
            JSONValueMark(valueRange: range(#""rgb(0, 128, 255)""#), kind: .color(JSONColor(red: 0, green: 128.0 / 255, blue: 1, alpha: 1))),
            JSONValueMark(valueRange: NSRange(location: range("1700000000,").location, length: 10), kind: .date(Date(timeIntervalSince1970: 1_700_000_000), milliseconds: false)),
            JSONValueMark(valueRange: range(#""1700000000123""#), kind: .date(Date(timeIntervalSince1970: 1_700_000_000.123), milliseconds: true)),
        ])
    }

    func testValueMarksIncludeDecodesAndJWTs() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIiwiZXhwIjoxNzY3MjI1NjAwfQ.c2ln"       // exp 1767225600
        let bare = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.c2ln"                          // no exp
        let doc = """
        [
          {"token": "\(jwt)", "plain": "\(bare)"},
          {
            "b": "aGVsbG8gd29ybGQgZnJvbSBqc29u", "q": "a%20b%2Fc", "words": "hello there, how are you",
            "list": [
              1,
              2,
              3
            ],
            "empty": {
            }
          }
        ]
        """
        let u = Array(doc.utf16)
        let ns = doc as NSString
        func quoted(_ value: String) -> NSRange { ns.range(of: "\"" + value + "\"") }
        XCTAssertEqual(JSONLocator.valueMarks(in: u), [
            JSONValueMark(valueRange: quoted(jwt), kind: .decode(jwtExpiry: Date(timeIntervalSince1970: 1_767_225_600))),
            JSONValueMark(valueRange: quoted(bare), kind: .decode(jwtExpiry: nil)),
            JSONValueMark(valueRange: quoted("aGVsbG8gd29ybGQgZnJvbSBqc29u"), kind: .decode(jwtExpiry: nil)),
            JSONValueMark(valueRange: quoted("a%20b%2Fc"), kind: .decode(jwtExpiry: nil)),
        ])
    }

    func testContainerSizeFollowsInnermostContext() throws {
        let source = #"{"items":[1,{"nested":[]},3],"empty":{},"flag":true}"#
        let ns = source as NSString
        let u = Array(source.utf16)
        func size(at text: String) -> JSONContainerSize? {
            JSONLocator.context(around: NSRange(location: ns.range(of: text).location, length: 0), in: u).size
        }
        XCTAssertEqual(size(at: source), .init(count: 3, isObject: true))
        XCTAssertEqual(size(at: "\"items\""), .init(count: 3, isObject: false))
        XCTAssertEqual(size(at: "1,"), .init(count: 3, isObject: false))
        XCTAssertEqual(size(at: "{\"nested"), .init(count: 1, isObject: true))
        XCTAssertEqual(size(at: "\"nested\""), .init(count: 0, isObject: false))
        XCTAssertEqual(size(at: "\"empty\""), .init(count: 0, isObject: true))
        XCTAssertEqual(size(at: "true"), .init(count: 3, isObject: true))
        XCTAssertNil(JSONLocator.context(around: NSRange(location: 0, length: 0), in: Array("123".utf16)).size)
        XCTAssertNil(JSONLocator.context(around: NSRange(location: 0, length: 0), in: []).size)
        let selection = ns.range(of: "[]},3")
        XCTAssertEqual(JSONLocator.context(around: selection, in: u).size, .init(count: 3, isObject: false))
    }

    func testContainerSizeSupportsUnfinishedJSONAndIsNotLimitedByMarks() {
        let source = "{\n  \"items\": [\n    1, 2, 3"
        let u = Array(source.utf16)
        XCTAssertEqual(JSONLocator.context(around: NSRange(location: u.count, length: 0), in: u).size,
                       .init(count: 3, isObject: false))
        let many = "[" + Array(repeating: "\"https://example.com\"", count: 2_100).joined(separator: ",") + ",[]]"
        let context = JSONLocator.context(around: NSRange(location: many.utf16.count - 2, length: 0),
                                          in: Array(many.utf16), collectMarks: true)
        XCTAssertEqual(context.marks.count, 2_000)
        XCTAssertEqual(context.size, .init(count: 0, isObject: false))
    }

    func testUnitsCopyTheWholeString() {
        XCTAssertEqual(JSONLocator.units(of: "a中😀" as NSString), Array("a中😀".utf16))
        XCTAssertEqual(JSONLocator.units(of: "" as NSString), [])
    }
}
