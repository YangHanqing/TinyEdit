import XCTest
@testable import TinyEdit

final class PasteDecodeDetectorTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    func testRecognition() {
        // `04114426` decodes to readable UTF-8, so the all-digit rule has to reject it on its own.
        // `12345678` is the same rule on a string whose bytes are not UTF-8.
        let rows: [(String, PasteDecodeKind?, String?)] = [
            ("SGVsbG8=", .base64, "Hello"),
            ("SGVsbG8=\n", .base64, "Hello"),
            ("\n  SGVsbG8=\n\n", .base64, "Hello"),
            ("SGVsbG8/", .base64, "Hello?"),
            ("SGVsbG8_", .base64, "Hello?"),
            ("password", nil, nil),
            ("04114426", nil, nil),
            ("12345678", nil, nil),
            ("iVBORw0KGgo=", nil, nil),
            ("%E4%B8%AD", .url, "中"),
            ("hello+world", nil, nil),
            ("https://example.com/path?q=1", nil, nil),
            ("SGVsbG8=\nSGVsbG8=", nil, nil),
            ("", nil, nil),
            ("\n", nil, nil),
            (#"\u4e2d\u6587"#, .unicodeEscape, "中文"),
            (#""line1\nline2""#, .jsonString, "line1\nline2"),
            (#""hello""#, nil, nil),
            (#"C:\new\table"#, nil, nil),
            ("1700000000", .timestamp, "2023-11-14T22:13:20Z"),
            ("1700000000123", .timestamp, "2023-11-14T22:13:20.123Z"),
            ("9999999999", nil, nil),        // year 2286
            ("0123456789", nil, nil),        // 1973
            ("170000000", nil, nil),
        ]
        for (document, kind, decoded) in rows {
            let got = PasteDecodeDetector.candidates(in: document, timeZone: utc)
            XCTAssertEqual(got?.map(\.kind), kind.map { [$0] }, document)
            XCTAssertEqual(got?.first?.decoded, decoded, document)
        }
    }

    /// Readings whose decode is a JSON object or array come back pretty-printed, marked as JSON.
    func testDecodesThatAreJSONArePrettyPrinted() {
        let pretty = "{\n  \"a\": 1\n}"
        let rows: [(String, PasteDecodeKind)] = [
            ("eyJhIjoxfQ==", .base64),
            ("eyJhIjoxfQ", .base64),
            (#"{\"a\":1}"#, .jsonString),
            (#""{\"a\":1}""#, .jsonString),
            ("%7B%22a%22%3A1%7D", .url),
        ]
        for (document, kind) in rows {
            let got = PasteDecodeDetector.candidates(in: document)
            XCTAssertEqual(got?.map(\.kind), [kind], document)
            XCTAssertEqual(got?.first?.decoded, pretty, document)
            XCTAssertEqual(got?.first?.isJSON, true, document)
        }
    }

    func testJWTIsNotAlsoOfferedAsBase64() throws {
        // {"alg":"HS256"} . {"sub":"1"} . signature
        for token in ["eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2ln", "Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2ln"] {
            let got = try XCTUnwrap(PasteDecodeDetector.candidates(in: token), token)
            XCTAssertEqual(got.map(\.kind), [.jwt], token)
            XCTAssertTrue(got[0].isJSON)
            XCTAssertTrue(got[0].decoded.contains("\"alg\": \"HS256\""), got[0].decoded)
        }
        XCTAssertNil(PasteDecodeDetector.candidates(in: "a.b.c"))
        XCTAssertNil(PasteDecodeDetector.candidates(in: "example.com"))
    }

    func testLanguageAndFormatOffer() {
        let minified = #"{"a":1,"b":[true,null]}"#
        let pretty = "{\n  \"a\": 1\n}\n"

        var got = PasteDecodeDetector.suggestion(in: minified, currentLanguage: .plain)
        XCTAssertEqual(got, PasteSuggestion(language: .json, canFormatJSON: true))
        got = PasteDecodeDetector.suggestion(in: pretty, currentLanguage: .javascript)
        XCTAssertEqual(got, PasteSuggestion(language: .json, canFormatJSON: false))
        // Already JSON: only the format offer is left, and nothing at all once it is formatted.
        got = PasteDecodeDetector.suggestion(in: minified, currentLanguage: .json)
        XCTAssertEqual(got, PasteSuggestion(language: nil, canFormatJSON: true))
        XCTAssertNil(PasteDecodeDetector.suggestion(in: pretty, currentLanguage: .json))
        // JSONC is JSON to the detector but not to Format JSON.
        got = PasteDecodeDetector.suggestion(in: "{\n  // c\n  \"a\": 1,\n}", currentLanguage: .plain)
        XCTAssertEqual(got, PasteSuggestion(language: .json, canFormatJSON: false))

        got = PasteDecodeDetector.suggestion(in: "const f = (x) => x;\nconsole.log(f(1));\n", currentLanguage: .json)
        XCTAssertEqual(got?.language, .javascript)
        got = PasteDecodeDetector.suggestion(in: "SGVsbG8=", currentLanguage: .plain)
        XCTAssertEqual(got?.candidates.map(\.kind), [.base64])
        XCTAssertNil(got?.language)
        XCTAssertNil(PasteDecodeDetector.suggestion(in: "just a note", currentLanguage: .plain))
    }
}
