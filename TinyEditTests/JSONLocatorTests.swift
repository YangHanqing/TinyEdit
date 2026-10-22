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

    func testImageValuesAreThePicturesPreviewWouldShow() {
        let doc = #"""
        {"avatar": "https://cdn.test/u/1", "home": "https://x.test/", "list": ["https://x.test/a.PNG", "b"],
         "icon": "data:image/png;base64,AAAA", "text": "data:text/plain,hi", "logo": "h\u0074tps://x.test/l",
         "nested": {"thumbnailUrl": "https://x.test/t?s=1"}, "escaped": "https:\/\/x.test\/e.jpg"}
        """#
        let u = Array(doc.utf16)
        let images = JSONLocator.imageValues(in: u)
        let ns = doc as NSString
        func range(_ value: String) -> NSRange { ns.range(of: "\"" + value + "\"") }
        XCTAssertEqual(images, [
            JSONImageValue(valueRange: range("https://cdn.test/u/1"), source: .remote),       // image-like key
            JSONImageValue(valueRange: range("https://x.test/a.PNG"), source: .remote),       // extension, in an array
            JSONImageValue(valueRange: range("data:image/png;base64,AAAA"), source: .inline),
            JSONImageValue(valueRange: range(#"h\u0074tps://x.test/l"#), source: .remote),
            JSONImageValue(valueRange: range("https://x.test/t?s=1"), source: .remote),
            JSONImageValue(valueRange: range("https:\\/\\/x.test\\/e.jpg"), source: .remote),  // escapes decoded
        ])
        // Each is the member a caret inside it finds, with the same picture.
        for image in images {
            let m = JSONLocator.member(around: NSRange(location: image.valueRange.location + 1, length: 0), in: u)
            XCTAssertEqual(m?.valueRange, image.valueRange)
            XCTAssertEqual(m.map { JSONValueInsight($0, in: u).image }, image.source)
        }
        XCTAssertEqual(JSONLocator.imageValues(in: u, limit: 2).count, 2)
        XCTAssertEqual(JSONLocator.imageValues(in: Array(#""https://x.test/a.png""#.utf16)), [])   // top level is not a member
    }

    func testUnitsCopyTheWholeString() {
        XCTAssertEqual(JSONLocator.units(of: "a中😀" as NSString), Array("a中😀".utf16))
        XCTAssertEqual(JSONLocator.units(of: "" as NSString), [])
    }
}
