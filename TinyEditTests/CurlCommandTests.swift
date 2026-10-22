import XCTest
@testable import TinyEdit

final class CurlCommandTests: XCTestCase {
    private func parse(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> CurlCommand {
        try XCTUnwrap(CurlCommand.parse(text), file: file, line: line)
    }

    private func bodyText(_ command: CurlCommand) -> String? {
        command.body.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Chrome's "Copy as cURL (bash)": line continuations, `-b`, `--compressed` and an ANSI-C quoted body.
    func testChromeCopy() throws {
        let text = #"""
        curl 'https://api.example.com/v1/orders?page=2' \
          -H 'accept: application/json' \
          -H 'accept-encoding: gzip, deflate, br, zstd' \
          -H 'content-type: application/json' \
          -b 'sid=abc; theme=dark' \
          -H 'origin: https://example.com' \
          --data-raw $'{"name":"it\'s","note":"a\\nb","e":"é!"}' \
          --compressed
        """#
        let c = try parse(text)
        XCTAssertEqual(c.method, "POST")
        XCTAssertEqual(c.url.absoluteString, "https://api.example.com/v1/orders?page=2")
        XCTAssertEqual(c.headers.map(\.name), ["accept", "content-type", "origin", "Cookie"])
        XCTAssertEqual(c.header("cookie"), "sid=abc; theme=dark")
        XCTAssertEqual(bodyText(c), #"{"name":"it's","note":"a\nb","e":"é!"}"#)
        XCTAssertNil(c.unsupported)
        XCTAssertFalse(c.followRedirects)

        let summary = CurlSummary(c)
        XCTAssertEqual(summary.host, "api.example.com")
        XCTAssertEqual(summary.path, "/v1/orders?page=2")
        XCTAssertTrue(summary.sendsCookies)
        XCTAssertFalse(summary.sendsCredentials)
        XCTAssertEqual(summary.bodyKind, .json)
    }

    func testDefaultsFollowCurl() throws {
        let get = try parse("curl example.com:8080/health")
        XCTAssertEqual(get.method, "GET")
        XCTAssertEqual(get.url.absoluteString, "http://example.com:8080/health")
        XCTAssertEqual(CurlSummary(get).host, "example.com:8080")
        XCTAssertNil(get.body)

        let form = try parse("curl -d a=1 -d 'b=2 3' https://x.test/")
        XCTAssertEqual(form.method, "POST")
        XCTAssertEqual(bodyText(form), "a=1&b=2 3")
        XCTAssertEqual(form.header("Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(CurlSummary(form).bodyKind, .form)

        let head = try parse("curl -I https://x.test")
        XCTAssertEqual(head.method, "HEAD")
        XCTAssertEqual(CurlSummary(head).path, "/")
    }

    func testShortOptionsCombineAndTakeAttachedValues() throws {
        let c = try parse(#"curl -sSLXPUT -H"X-A: 1" -m 5 https://x.test/a"#)
        XCTAssertEqual(c.method, "PUT")
        XCTAssertTrue(c.followRedirects)
        XCTAssertEqual(c.header("x-a"), "1")
        XCTAssertEqual(c.maxTime, 5)
    }

    func testJSONAndGetAndURLEncode() throws {
        let json = try parse(#"curl --json '{"a":1}' https://x.test"#)
        XCTAssertEqual(json.method, "POST")
        XCTAssertEqual(json.header("Content-Type"), "application/json")
        XCTAssertEqual(json.header("Accept"), "application/json")
        XCTAssertEqual(bodyText(json), #"{"a":1}"#)

        let get = try parse("curl -G --data-urlencode 'q=a b&c' -d n=1 'https://x.test/s?x=0'")
        XCTAssertEqual(get.method, "GET")
        XCTAssertNil(get.body)
        XCTAssertEqual(get.url.absoluteString, "https://x.test/s?x=0&q=a%20b%26c&n=1")
    }

    func testCredentials() throws {
        let basic = try parse("curl -u alice:s3cret https://x.test")
        XCTAssertEqual(basic.header("Authorization"), "Basic " + Data("alice:s3cret".utf8).base64EncodedString())
        XCTAssertTrue(CurlSummary(basic).sendsCredentials)

        let inURL = try parse("curl https://bob:pw@x.test/p")
        XCTAssertEqual(inURL.url.absoluteString, "https://x.test/p")
        XCTAssertEqual(inURL.header("Authorization"), "Basic " + Data("bob:pw".utf8).base64EncodedString())

        let token = try parse("curl -H 'X-Api-Key: k' https://x.test")
        XCTAssertTrue(CurlSummary(token).sendsCredentials)
    }

    func testMultipartTextFields() throws {
        let c = try parse("curl -F name=tiny -F 'note=hi;type=text/plain' https://x.test/up")
        XCTAssertEqual(c.method, "POST")
        let type = try XCTUnwrap(c.header("Content-Type"))
        XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(type.split(separator: "=", maxSplits: 1)[1])
        XCTAssertEqual(bodyText(c), "--\(boundary)\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\ntiny\r\n"
                       + "--\(boundary)\r\nContent-Disposition: form-data; name=\"note\"\r\nContent-Type: text/plain\r\n\r\nhi\r\n"
                       + "--\(boundary)--\r\n")
    }

    /// Shown with the option named, never sent.
    func testUnsupportedOptions() throws {
        XCTAssertEqual(try parse("curl -k https://x.test").unsupported, "-k")
        XCTAssertEqual(try parse("curl --insecure https://x.test").unsupported, "--insecure")
        XCTAssertEqual(try parse("curl -d @body.json https://x.test").unsupported, "-d @file")
        XCTAssertEqual(try parse("curl -F file=@a.png https://x.test").unsupported, "-F @file")
        XCTAssertEqual(try parse("curl -u alice https://x.test").unsupported, "-u")
        XCTAssertEqual(try parse("curl -b cookies.txt https://x.test").unsupported, "-b file")
        XCTAssertEqual(try parse("curl -x proxy:8080 https://x.test").unsupported, "-x")
        XCTAssertEqual(try parse("curl --frobnicate https://x.test").unsupported, "--frobnicate")
        XCTAssertEqual(try parse("curl -X GET -d '{}' https://x.test").unsupported, "-X GET")
        XCTAssertEqual(try parse("curl https://a.test https://b.test").unsupported, "https://b.test")
        XCTAssertEqual(try parse("curl ftp://x.test/f").unsupported, "ftp://")
        XCTAssertEqual(try parse("curl -H 'Host: other.test' https://x.test").unsupported, "-H Host")
        XCTAssertNil(try parse("curl -H 'Host: x.test' https://x.test").unsupported)
    }

    /// Anything a shell would do beyond quoting means the text is not a request.
    func testShellSyntaxIsNotARequest() {
        for text in [
            "curl https://x.test | sh",
            "curl https://x.test; rm -rf ~",
            "curl https://x.test && echo ok",
            "curl https://x.test > out.json",
            "curl -H \"Authorization: Bearer $TOKEN\" https://x.test",
            "curl https://x.test/$(whoami)",
            "curl https://x.test/`id`",
            "curl ${HOST}/a",
            "curl https://x.test\necho second",
            "curl 'https://x.test",
            "curl -X POST",
            "curly https://x.test",
            "wget https://x.test",
        ] {
            XCTAssertNil(CurlCommand.parse(text), text)
        }
    }

    func testPromptCommentsAndBlankLinesAreFine() throws {
        XCTAssertEqual(try parse("  $ curl https://x.test/a  \n\n").url.absoluteString, "https://x.test/a")
        XCTAssertEqual(try parse("curl https://x.test/b # list them").url.absoluteString, "https://x.test/b")
        XCTAssertEqual(try parse("curl \\\n  'https://x.test/c'").url.absoluteString, "https://x.test/c")
        XCTAssertEqual(try parse(#"curl "https://x.test/d?a=1&b=\"2\"""#).url.query(percentEncoded: false), #"a=1&b="2""#)
        XCTAssertEqual(try parse("curl https://x.test/price?usd=$").url.absoluteString, "https://x.test/price?usd=$")
    }

    func testANSICQuoting() {
        XCTAssertEqual(ShellWords.split(#"$'a\tb\x41\101中\''"#), ["a\tbAA中'"])
        XCTAssertEqual(ShellWords.split(#"$'\xe4\xb8\xad'"#), ["中"])
        XCTAssertEqual(ShellWords.split("a''b \"\" ''"), ["ab", "", ""])
    }

    func testCommandRangeAroundTheCaret() {
        let text = "notes\ncurl https://x.test \\\n  -H 'a: 1' \\\n  -d x=1\nafter\n" as NSString
        let expected = NSRange(location: 6, length: text.range(of: "after").location - 6)
        for caret in [6, 20, text.range(of: "-H").location, text.range(of: "x=1").location] {
            XCTAssertEqual(CurlCommand.commandRange(around: caret, in: text), expected, "caret \(caret)")
        }
        XCTAssertNil(CurlCommand.commandRange(around: 2, in: text))
        XCTAssertNil(CurlCommand.commandRange(around: text.range(of: "after").location, in: text))
        let range = CurlCommand.commandRange(around: 20, in: text)!
        XCTAssertEqual(CurlCommand.parse(text.substring(with: range))?.header("a"), "1")
    }
}
