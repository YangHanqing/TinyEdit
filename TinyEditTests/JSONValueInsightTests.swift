import XCTest
@testable import TinyEdit

final class JSONValueInsightTests: XCTestCase {
    private static let png1x1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

    /// The insight of the member around `marker` (its offset in `json`, marker removed).
    private func insight(_ json: String) throws -> JSONValueInsight {
        let caret = (json as NSString).range(of: "‸").location
        let text = (json as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
        let units = JSONLocator.units(of: text as NSString)
        let member = try XCTUnwrap(JSONLocator.member(around: NSRange(location: caret, length: 0), in: units))
        return JSONValueInsight(member, in: units)
    }

    // MARK: JWT expiry

    func testJWTExpiry() {
        let header = "eyJhbGciOiJIUzI1NiJ9"
        XCTAssertEqual(JSONValueInsight.jwtExpiry(header + ".eyJzdWIiOiIxIiwiZXhwIjoxNzY3MjI1NjAwfQ.c2ln"),
                       Date(timeIntervalSince1970: 1_767_225_600))
        XCTAssertEqual(JSONValueInsight.jwtExpiry("Bearer " + header + ".eyJzdWIiOiIxIiwiZXhwIjoxNzY3MjI1NjAwfQ"),
                       Date(timeIntervalSince1970: 1_767_225_600))
        XCTAssertNil(JSONValueInsight.jwtExpiry(header + ".eyJzdWIiOiIxMjMifQ.c2ln"))          // no exp
        XCTAssertNil(JSONValueInsight.jwtExpiry(header + ".eyJleHAiOiJzb29uIn0.c2ln"))         // {"exp":"soon"}
        XCTAssertNil(JSONValueInsight.jwtExpiry(header + ".eyJleHAiOnRydWV9.c2ln"))            // {"exp":true}
        XCTAssertNil(JSONValueInsight.jwtExpiry("not.a.jwt"))
    }

    func testExpiryText() {
        let utc = TimeZone(identifier: "UTC")!
        let expiry = Date(timeIntervalSince1970: 1_767_225_600)
        let en = Locale(identifier: "en")
        let past = JSONValueInsight.expiryText(expiry, now: expiry.addingTimeInterval(60), timeZone: utc, locale: en)
        XCTAssertEqual(past.text, "exp 2026-01-01 00:00")
        XCTAssertTrue(past.expired)
        let future = JSONValueInsight.expiryText(expiry, now: expiry.addingTimeInterval(-3 * 86_400), timeZone: utc, locale: en)
        XCTAssertEqual(future.status, "in 3 days")
        XCTAssertFalse(future.expired)
        let zh = JSONValueInsight.expiryText(expiry, now: expiry.addingTimeInterval(-3 * 86_400), timeZone: utc,
                                             locale: Locale(identifier: "zh-Hans"))
        XCTAssertEqual(zh.status, "3天后")
    }

    func testMarkOptionsHideOrReduceKinds() {
        let expiry = Date(timeIntervalSince1970: 1_767_225_600)
        var options = JSONMarkOptions()
        XCTAssertEqual(options.shown(.decode(jwtExpiry: expiry)), .decode(jwtExpiry: expiry))
        options.jwtExpiry = false
        XCTAssertEqual(options.shown(.decode(jwtExpiry: expiry)), .decode(jwtExpiry: nil))      // falls back to the icon
        options.decodes = false
        XCTAssertNil(options.shown(.decode(jwtExpiry: expiry)))
        options.jwtExpiry = true
        XCTAssertEqual(options.shown(.decode(jwtExpiry: expiry)), .decode(jwtExpiry: expiry))
        XCTAssertNil(options.shown(.decode(jwtExpiry: nil)))
        options.links = false
        XCTAssertNil(options.shown(.link(URL(string: "https://x.test")!)))
        XCTAssertEqual(options.shown(.image(.remote)), .image(.remote))
    }

    // MARK: Links

    func testLinks() throws {
        let plain = try insight(#"{"home": "‸https://example.com/docs"}"#)
        XCTAssertEqual(plain.link, URL(string: "https://example.com/docs"))
        XCTAssertFalse(plain.linkHasQuery)
        XCTAssertNil(plain.image)

        let query = try insight(#"{"next": "‸https://api.test/v1/items?page=2&tag=a&tag=b"}"#)
        XCTAssertTrue(query.linkHasQuery)

        XCTAssertNil(try insight(#"{"a": "‸ftp://example.com/x"}"#).link)
        XCTAssertNil(try insight(#"{"a": "‸https://exa mple.com"}"#).link)
        XCTAssertNil(try insight(#"{"a": "‸see https://example.com"}"#).link)
        XCTAssertNil(try insight(#"{"a": "‸https://"}"#).link)
        XCTAssertEqual(try insight(#"{"a": "‸HTTP://localhost:8080/"}"#).link?.host(), "localhost")
    }

    func testImagesByExtensionKeyOrDataURI() throws {
        XCTAssertEqual(try insight(#"{"src": "‸https://cdn.test/a/b.PNG?w=200"}"#).image, .remote)
        XCTAssertEqual(try insight(#"{"avatarUrl": "‸https://avatars.test/u/1?v=4"}"#).image, .remote)
        XCTAssertEqual(try insight(#"{"profile_images": "‸https://x.test/u/1"}"#).image, .remote)
        XCTAssertNil(try insight(#"{"topic": "‸https://x.test/t/1"}"#).image)            // `pic` only as a word
        XCTAssertNil(try insight(#"{"homepage": "‸https://x.test/"}"#).image)
        let inline = try insight(#"{"icon": "‸data:image/png;base64,\#(Self.png1x1)"}"#)
        XCTAssertEqual(inline.image, .inline)
        XCTAssertNil(inline.link)
        XCTAssertTrue(inline.decodes.isEmpty)
    }

    func testLongDataImageIsFoundFromItsPrefix() throws {
        let long = "data:image/png;base64," + String(repeating: "A", count: JSONValueInsight.detailLimit + 10)
        XCTAssertEqual(try insight("{\"i\": \"‸\(long)\"}").image, .inline)
        let text = String(repeating: "x", count: JSONValueInsight.detailLimit + 10)
        XCTAssertEqual(try insight("{\"t\": \"‸\(text)\"}"), JSONValueInsight())
    }

    func testKeyWords() {
        XCTAssertEqual(JSONValueInsight.words(of: "profile_imageURL"), ["profile", "image", "url"])
        XCTAssertEqual(JSONValueInsight.words(of: "thumbnailUrl2x"), ["thumbnail", "url2x"])
        XCTAssertEqual(JSONValueInsight.words(of: "og:image"), ["og", "image"])
    }

    func testQueryJSON() throws {
        let url = try XCTUnwrap(URL(string: "https://x.test/s?q=caf%C3%A9%20au%20lait&tag=a&tag=b&flag&n=1+2"))
        XCTAssertEqual(JSONValueInsight.queryJSON(url), """
        {
          "q": "café au lait",
          "tag": [
            "a",
            "b"
          ],
          "flag": null,
          "n": "1+2"
        }
        """)
        XCTAssertNil(JSONValueInsight.queryJSON(try XCTUnwrap(URL(string: "https://x.test/s"))))
        XCTAssertEqual(JSONValueInsight.quoted("a\"b\\c\n\u{1}"), #""a\"b\\c\n\u0001""#)
    }

    // MARK: Decodes

    func testDecodesOfferedOnStrings() throws {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.c2ln"
        XCTAssertEqual(try insight("{\"token\": \"‸\(jwt)\"}").decodes, [.jwt])
        XCTAssertEqual(try insight(#"{"b": "‸aGVsbG8gd29ybGQgZnJvbSBqc29u"}"#).decodes, [.base64])
        XCTAssertEqual(try insight(#"{"q": "‸a%20b%2Fc"}"#).decodes, [.url])
        XCTAssertEqual(try insight(#"{"u": "‸\\u4f60\\u597d"}"#).decodes, [.unicodeEscape])
        XCTAssertEqual(try insight(#"{"next": "‸https://x.test/?q=a%20b"}"#).decodes, [.url])
        XCTAssertEqual(try insight(#"{"word": "‸password"}"#).decodes, [])                // too short for Base64
        XCTAssertEqual(try insight(#"{"name": "‸Ada Lovelace"}"#), JSONValueInsight())
        XCTAssertEqual(try insight(#"{"o": ‸{"a": 1}}"#), JSONValueInsight())
    }

    // MARK: Dates

    func testUnixTimestamps() throws {
        let seconds = try insight(#"{"created": ‸1700000000}"#)
        XCTAssertEqual(seconds.date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertFalse(seconds.dateHasMilliseconds)
        let ms = try insight(#"{"t": "‸1700000000123"}"#)
        XCTAssertEqual(ms.date, Date(timeIntervalSince1970: 1_700_000_000.123))
        XCTAssertTrue(ms.dateHasMilliseconds)
        XCTAssertTrue(ms.decodes.isEmpty)
        XCTAssertNil(try insight(#"{"n": ‸123456}"#).date)
        XCTAssertNil(try insight(#"{"n": ‸9999999999}"#).date)                           // after 2100
        XCTAssertNil(try insight(#"{"n": ‸1700000000.5}"#).date)
        XCTAssertNil(try insight(#"{"n": ‸-170000000}"#).date)

        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        XCTAssertEqual(JSONValueInsight.dateText(Date(timeIntervalSince1970: 1_700_000_000), milliseconds: false, timeZone: utc),
                       "2023-11-14 22:13:20")
        XCTAssertEqual(JSONValueInsight.dateText(Date(timeIntervalSince1970: 1_700_000_000.123), milliseconds: true, timeZone: tokyo),
                       "2023-11-15 07:13:20.123")
        XCTAssertEqual(JSONValueInsight.offsetText(.now, timeZone: tokyo), "UTC+9")
        XCTAssertEqual(JSONValueInsight.offsetText(.now, timeZone: utc), "UTC")
        XCTAssertEqual(JSONValueInsight.offsetText(.now, timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: -(3 * 3600 + 1800)))),
                       "UTC−3:30")
    }

    // MARK: Colors

    func testColors() {
        XCTAssertEqual(JSONValueInsight.color("#fff"), JSONColor(red: 1, green: 1, blue: 1, alpha: 1))
        XCTAssertEqual(JSONValueInsight.color("#FF000080"), JSONColor(red: 1, green: 0, blue: 0, alpha: 128.0 / 255))
        XCTAssertEqual(JSONValueInsight.color("#0f08"), JSONColor(red: 0, green: 1, blue: 0, alpha: 136.0 / 255))
        XCTAssertEqual(JSONValueInsight.color("rgb(255, 0, 51)"), JSONColor(red: 1, green: 0, blue: 0.2, alpha: 1))
        XCTAssertEqual(JSONValueInsight.color("rgba(0,0,0,0.5)"), JSONColor(red: 0, green: 0, blue: 0, alpha: 0.5))
        XCTAssertEqual(JSONValueInsight.color("rgb(100% 0% 0% / 50%)"), JSONColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        let hsl = JSONValueInsight.color("hsl(120, 100%, 50%)")
        XCTAssertEqual(hsl?.red ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(hsl?.green ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(hsl?.blue ?? -1, 0, accuracy: 1e-9)
        for bad in ["#ggg", "#12345", "fff", "rgb(256,0,0)", "rgb(1,2)", "hsl(0, 50, 50)", "red", "#"] {
            XCTAssertNil(JSONValueInsight.color(bad), bad)
        }
    }

    func testColorStringInDocument() throws {
        let found = try insight(#"{"accent": "‸#3366FF"}"#)
        XCTAssertEqual(found.color, JSONColor(red: 0.2, green: 0.4, blue: 1, alpha: 1))
        XCTAssertTrue(found.decodes.isEmpty)
    }

    // MARK: Data URIs

    func testDataURIs() throws {
        let png = try XCTUnwrap(DataURI.parse("data:image/png;base64,\(Self.png1x1)"))
        XCTAssertEqual(png.mimeType, "image/png")
        XCTAssertEqual(png.fileExtension, "png")
        XCTAssertEqual(Array(png.data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let unpadded = try XCTUnwrap(DataURI.parse("data:image/png;base64,\(Self.png1x1.replacingOccurrences(of: "=", with: ""))"))
        XCTAssertEqual(unpadded.data, png.data)
        let svg = try XCTUnwrap(DataURI.parse("data:image/svg+xml;utf8,%3Csvg%20xmlns='http://www.w3.org/2000/svg'/%3E"))
        XCTAssertEqual(String(decoding: svg.data, as: UTF8.self), "<svg xmlns='http://www.w3.org/2000/svg'/>")
        XCTAssertEqual(svg.fileExtension, "svg")
        XCTAssertEqual(DataURI.fileExtension(forMIMEType: "image/jpeg"), "jpg")
        XCTAssertNil(DataURI.parse("data:image/png;base64,"))
        XCTAssertNil(DataURI.parse("image/png;base64,AAAA"))
        XCTAssertEqual(AppState.fileName("items[0]/a:b", extension: "png"), "items[0]-a-b.png")
    }

    // MARK: Download

    private func stubbed() -> URLSessionConfiguration {
        let config = CurlRunner.makeConfiguration()
        config.protocolClasses = [CurlStubProtocol.self]
        return config
    }

    func testRemoteImageLoads() async throws {
        let png = try XCTUnwrap(Data(base64Encoded: Self.png1x1))
        CurlStubProtocol.respond = { _ in (200, ["Content-Type": "image/png"], png) }
        let loaded = try await RemoteImageLoader.load(try XCTUnwrap(URL(string: "https://img.test/a.png")), configuration: stubbed())
        XCTAssertEqual(loaded.data, png)
        XCTAssertEqual(loaded.mimeType, "image/png")
        XCTAssertEqual(CurlStubProtocol.lastRequest?.httpMethod, "GET")
    }

    func testRemoteImageRefusesErrorsAndPages() async throws {
        let url = try XCTUnwrap(URL(string: "https://img.test/a.png"))
        CurlStubProtocol.respond = { _ in (404, ["Content-Type": "image/png"], Data("x".utf8)) }
        do {
            _ = try await RemoteImageLoader.load(url, configuration: stubbed())
            XCTFail("a 404 is not a picture")
        } catch let failure as ImagePreviewFailure {
            XCTAssertEqual(failure, .status(404))
        }
        CurlStubProtocol.respond = { _ in (200, ["Content-Type": "text/html; charset=utf-8"], Data("<html>".utf8)) }
        do {
            _ = try await RemoteImageLoader.load(url, configuration: stubbed())
            XCTFail("a page is not a picture")
        } catch let failure as ImagePreviewFailure {
            XCTAssertEqual(failure, .notImage)
        }
    }
}
