import XCTest
@testable import TinyEdit

/// Answers every request in the test session with `respond`, and keeps the last request it saw.
final class CurlStubProtocol: URLProtocol {
    nonisolated(unsafe) static var respond: (URLRequest) -> (status: Int, headers: [String: String], body: Data) = { _ in
        (200, [:], Data())
    }
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let reply = Self.respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

final class CurlRunnerTests: XCTestCase {
    private func stubbedConfiguration() -> URLSessionConfiguration {
        let config = CurlRunner.makeConfiguration()
        config.protocolClasses = [CurlStubProtocol.self]
        return config
    }

    func testRequestCarriesTheCommand() throws {
        let command = try XCTUnwrap(CurlCommand.parse(
            "curl -X PATCH -H 'X-A: 1' -H 'X-A: 2' -H 'Cookie: a=1' -b b=2 -d k=v -m 7 https://x.test/p"))
        let request = CurlRunner.request(for: command)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-A"), "1, 2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "a=1; b=2")
        XCTAssertEqual(request.httpBody, Data("k=v".utf8))
        XCTAssertEqual(request.timeoutInterval, 7)
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testSendReturnsStatusHeadersAndBody() async throws {
        CurlStubProtocol.respond = { _ in (201, ["Content-Type": "application/json", "X-Id": "9"], Data(#"{"id":9}"#.utf8)) }
        let command = try XCTUnwrap(CurlCommand.parse(#"curl https://x.test/items --json '{"n":1}'"#))
        let response = try await CurlRunner.send(command, configuration: stubbedConfiguration())
        XCTAssertEqual(response.status, 201)
        XCTAssertTrue(response.headers.contains(CurlCommand.Header(name: "X-Id", value: "9")))
        XCTAssertEqual(CurlStubProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(CurlStubProtocol.lastBody, Data(#"{"n":1}"#.utf8))
        XCTAssertEqual(CurlRunner.body(of: response), .text("{\n  \"id\": 9\n}", language: .json))
        XCTAssertEqual(CurlRunner.reason(for: response.status), "Created")
    }

    private func response(_ body: Data, mime: String?, charset: String? = nil) -> CurlResponse {
        CurlResponse(status: 200, headers: [], body: body, mimeType: mime, textEncodingName: charset, elapsed: .zero)
    }

    func testBodyDecoding() throws {
        XCTAssertEqual(CurlRunner.body(of: response(Data(), mime: "text/plain")), .empty)
        XCTAssertEqual(CurlRunner.body(of: response(Data([0x89, 0x50, 0x4E, 0x47]), mime: "image/png")),
                       .binary(mimeType: "image/png"))
        XCTAssertEqual(CurlRunner.body(of: response(Data("a\0b".utf8), mime: "text/plain")), .binary(mimeType: "text/plain"))
        XCTAssertEqual(CurlRunner.body(of: response(Data("a\r\nb".utf8), mime: "text/plain")), .text("a\nb", language: nil))
        XCTAssertEqual(CurlRunner.body(of: response(Data("<p>x</p>".utf8), mime: "text/html")),
                       .text("<p>x</p>", language: .html))
        XCTAssertEqual(CurlRunner.body(of: response(Data("a=1".utf8), mime: "application/x-www-form-urlencoded")),
                       .text("a=1", language: nil))
        // The server's charset wins; without one, GB18030 is the same fallback as opening a file.
        let gbk = try XCTUnwrap("中文".data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))))
        XCTAssertEqual(CurlRunner.body(of: response(gbk, mime: "text/plain", charset: "gbk")), .text("中文", language: nil))
        XCTAssertEqual(CurlRunner.body(of: response(gbk, mime: "text/plain")), .text("中文", language: nil))
        let latin1 = try XCTUnwrap("café".data(using: .isoLatin1))
        XCTAssertEqual(CurlRunner.body(of: response(latin1, mime: "text/plain", charset: "iso-8859-1")),
                       .text("café", language: nil))
    }

    @MainActor func testTabTitleNamesTheRequest() throws {
        let command = try XCTUnwrap(CurlCommand.parse("curl -X DELETE 'https://x.test/v1/items/9?force=1'"))
        XCTAssertEqual(AppState.curlTabTitle(CurlSummary(command), status: 204), "DELETE /v1/items/9 · 204")
    }
}
