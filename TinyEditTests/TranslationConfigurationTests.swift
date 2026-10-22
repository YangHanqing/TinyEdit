import XCTest
@testable import TinyEdit

final class TranslationConfigurationTests: XCTestCase {
    private func preferences() -> TranslationPreferences {
        var p = TranslationPreferences()
        p.engine = .custom; p.model = "test-model"
        p.endpoint = "https://fixture.invalid/success"
        return p
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testThinkingDefaultSendsNoExtensionFields() throws {
        for format in TranslationThinkingFormat.allCases {
            var p = preferences(); p.thinkingFormat = format
            let json = try body(ModelTranslation.request(text: "Hello", source: nil, target: "ko", preferences: p, key: ""))
            for key in ["reasoning_effort", "thinking", "enable_thinking", "chat_template_kwargs"] { XCTAssertNil(json[key]) }
        }
    }

    func testThinkingOnAndOffUseOnlyChosenWireFormat() throws {
        for mode in [TranslationThinking.off, .on] {
            let on = mode == .on
            for format in TranslationThinkingFormat.allCases {
                var p = preferences(); p.thinking = mode; p.thinkingFormat = format
                let json = try body(ModelTranslation.request(text: "Hello", source: "en", target: "ko", preferences: p, key: ""))
                switch format {
                case .openAI: XCTAssertEqual(json["reasoning_effort"] as? String, on ? "medium" : "none")
                case .deepSeek: XCTAssertEqual((json["thinking"] as? [String: String])?["type"], on ? "enabled" : "disabled")
                case .enableThinking: XCTAssertEqual(json["enable_thinking"] as? Bool, on)
                case .chatTemplate: XCTAssertEqual((json["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], on)
                }
                XCTAssertEqual(json.keys.filter { ["reasoning_effort", "thinking", "enable_thinking", "chat_template_kwargs"].contains($0) }.count, 1)
            }
        }
    }

    func testConnectionProbeUsesCurrentModelAndFlagsButNoPersonalInstructions() throws {
        var p = preferences(); p.thinking = .off; p.thinkingFormat = .deepSeek
        p.extraInstructions = "Private terminology that must not enter the test."
        let request = try ModelTranslation.connectionTestRequest(preferences: p, key: "dummy-key")
        let json = try body(request)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(request.url?.absoluteString, p.endpoint)
        XCTAssertEqual(request.timeoutInterval, ModelTranslation.probeTimeout)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer dummy-key")
        XCTAssertEqual(json["model"] as? String, p.model)
        XCTAssertEqual((json["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual(messages[1]["content"], "Hello")
        XCTAssertFalse(messages.contains { ($0["content"] ?? "").contains(p.extraInstructions) })
    }

    func testSavedMaskNeverBecomesAStoredOrSentCredential() throws {
        var draft = TranslationCredentialDraft()
        draft.hasSavedKey = true
        XCTAssertTrue(draft.showsSavedMask)
        XCTAssertEqual(draft.value, "")
        var writes: [String] = []
        try draft.persist { writes.append($0) }
        XCTAssertEqual(writes, [])
        XCTAssertEqual(try draft.keyForRequest { "saved-secret" }, "saved-secret")
        draft.edit("replacement-secret")
        XCTAssertFalse(draft.showsSavedMask)
        XCTAssertEqual(try draft.keyForRequest { XCTFail("Edited draft must not read old credential"); return "old" }, "replacement-secret")
        try draft.persist { writes.append($0) }
        draft.didSave()
        XCTAssertEqual(writes, ["replacement-secret"])
        XCTAssertTrue(draft.showsSavedMask)
        XCTAssertEqual(draft.value, "")
    }

    func testRemovalAndFailedSaveRetainCorrectDraftState() throws {
        var draft = TranslationCredentialDraft(); draft.hasSavedKey = true
        draft.edit("")
        XCTAssertFalse(draft.showsSavedMask)
        XCTAssertEqual(try draft.keyForRequest { XCTFail("Removal must not reuse saved key"); return "old" }, "")
        XCTAssertThrowsError(try draft.persist { _ in throw TranslationFailure.keychain })
        XCTAssertTrue(draft.isEdited)
        var written: String?
        try draft.persist { written = $0 }
        draft.didSave()
        XCTAssertEqual(written, "")
        XCTAssertFalse(draft.hasSavedKey)
        XCTAssertFalse(draft.showsSavedMask)
    }

    func testConnectionSuccessRejectsAuthErrorsMalformedOrEmptyResponses() async throws {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        try await ModelTranslation.testConnection(preferences: preferences(), key: "dummy", session: session)
        for path in ["unauthorized", "malformed", "empty", "truncated"] {
            var p = preferences(); p.endpoint = "https://fixture.invalid/" + path
            do {
                try await ModelTranslation.testConnection(preferences: p, key: "dummy", session: session)
                XCTFail("Probe must fail for \(path)")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("dummy"))
                if path == "unauthorized" { XCTAssertTrue(error.localizedDescription.contains("•••• credential rejected")) }
            }
        }
    }

    func testConnectionTimeoutHasProbeSpecificFeedback() async {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        var p = preferences(); p.endpoint = "https://fixture.invalid/timeout"
        do {
            try await ModelTranslation.testConnection(preferences: p, key: "", session: session)
            XCTFail("Timeout must fail the probe")
        } catch {
            guard let failure = error as? TranslationFailure, case .connectionTimeout = failure else {
                XCTFail("Expected a connection-test timeout, got \(error)"); return
            }
        }
    }

    func testConnectionProbeCancellationDoesNotReportSuccess() async {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        var p = preferences(); p.endpoint = "https://fixture.invalid/pending"
        let config = p
        let task = Task { try await ModelTranslation.testConnection(preferences: config, key: "", session: session) }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled probe must not succeed") } catch {}
    }

    private func fixtureSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TranslationFixtureProtocol.self]
        return URLSession(configuration: config)
    }
}

/// No network, credentials or process-global mutable handlers in the transport tests.
private final class TranslationFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.lastPathComponent ?? ""
        if path == "pending" { return }
        if path == "timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let status = path == "unauthorized" ? 401 : 200
        let data: Data
        switch path {
        case "unauthorized": data = Data(#"{"error":{"message":"dummy credential rejected"}}"#.utf8)
        case "malformed": data = Data("not JSON".utf8)
        case "empty": data = Data(#"{"choices":[{"message":{"content":""}}]}"#.utf8)
        case "truncated": data = Data(#"{"choices":[{"message":{"content":"partial"},"finish_reason":"length"}]}"#.utf8)
        default: data = Data(#"{"choices":[{"message":{"content":"你好","reasoning_content":"hidden"},"finish_reason":"stop"}]}"#.utf8)
        }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
