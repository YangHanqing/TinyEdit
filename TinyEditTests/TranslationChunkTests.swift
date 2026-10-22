import XCTest
@testable import TinyEdit

final class TranslationChunkTests: XCTestCase {
    func testReconstructionPreservesParagraphsWhitespaceAndFences() {
        let text = "  Hello world!\nwrapped line.\n\n\t\n```swift\nlet x = 1\n```\n\nSecond paragraph.\n"
        let segments = TranslationPlan.make(text, limit: 20)
        XCTAssertEqual(segments.map(\.text).joined(), text)
        XCTAssertTrue(segments.contains { !$0.needsTranslation && $0.text == "```swift\nlet x = 1\n```\n" })
        XCTAssertFalse(segments.filter(\.needsTranslation).contains { $0.text.contains("let x") })
        XCTAssertTrue(segments.filter(\.needsTranslation).allSatisfy { $0.text.utf16.count <= 20 })
    }

    func testOversizedParagraphsAndUnicodeRemainIntact() {
        for text in [String(repeating: "한글 문장입니다. ", count: 1000),
                     String(repeating: "👨‍👩‍👧‍👦你好。", count: 1000),
                     String(repeating: "word ", count: 1000), String(repeating: "a", count: 10_000)] {
            let segments = TranslationPlan.make(text, limit: 80)
            XCTAssertEqual(segments.map(\.text).joined(), text)
            XCTAssertTrue(segments.filter(\.needsTranslation).allSatisfy { $0.text.utf16.count <= 80 })
            XCTAssertGreaterThan(segments.filter(\.needsTranslation).count, 1)
        }
    }

    func testLongAndUnclosedCodeFencesAreNeverSent() {
        for text in ["~~~python\n" + String(repeating: "print(1)\n", count: 1000) + "~~~~\n",
                     "```\nNever closed\n\nStill code"] {
            let segments = TranslationPlan.make(text, limit: 20)
            XCTAssertEqual(segments.map(\.text).joined(), text)
            XCTAssertFalse(segments.contains(where: \.needsTranslation))
        }
    }

    func testModelPlanPacksWholeParagraphsUpToTheLimit() {
        let paragraphs = (1...6).map { "Paragraph \($0) has some words." }
        let text = "\n" + paragraphs.joined(separator: "\n\n") + "\n\n```\ncode\n```\nAfter fence.\n"
        let segments = TranslationPlan.make(text, limit: 70, joinParagraphs: true)
        XCTAssertEqual(segments.map(\.text).joined(), text)
        let parts = segments.filter(\.needsTranslation).map(\.text)
        XCTAssertEqual(parts, [paragraphs[0] + "\n\n" + paragraphs[1], paragraphs[2] + "\n\n" + paragraphs[3],
                               paragraphs[4] + "\n\n" + paragraphs[5], "After fence."])
        XCTAssertEqual(TranslationPlan.make(text, for: .apple).filter(\.needsTranslation).count, 7)
        XCTAssertEqual(TranslationPlan.make(text, for: .custom).filter(\.needsTranslation).count, 2)
    }

    func testSplitPrefersABlankLineInsideAPackedPart() {
        let text = String(repeating: "a", count: 200) + ". b\n\n" + String(repeating: "c. ", count: 100)
        let first = TranslationPlan.split(text, limit: 300).first { $0.needsTranslation }?.text
        XCTAssertEqual(first, String(repeating: "a", count: 200) + ". b")
    }

    func testEmptyAndWhitespaceOnlyPlans() {
        XCTAssertTrue(TranslationPlan.make("").isEmpty)
        let text = " \n\n\t\n"
        let segments = TranslationPlan.make(text)
        XCTAssertEqual(segments.map(\.text).joined(), text)
        XCTAssertFalse(segments.contains(where: \.needsTranslation))
    }

    func testClearCapacityErrorsAreRecognizedButOther400sAreNot() {
        for code in ["context_length_exceeded", "input_too_long"] {
            let data = Data("{\"error\":{\"code\":\"\(code)\"}}".utf8)
            XCTAssertThrowsError(try ModelTranslation.decode(data, status: 400)) { error in
                XCTAssertEqual((error as? TranslationFailure)?.shouldReduceChunk, true)
            }
        }
        XCTAssertThrowsError(try ModelTranslation.decode(Data(), status: 413)) { error in
            XCTAssertEqual((error as? TranslationFailure)?.shouldReduceChunk, true)
        }
        XCTAssertThrowsError(try ModelTranslation.decode(Data(), status: 400)) { error in
            XCTAssertEqual((error as? TranslationFailure)?.shouldReduceChunk, false)
        }
    }

    func testCapacityErrorsFromNonOpenAIServicesAreRecognized() {
        let bodies = [
            #"{"object":"error","message":"This model's maximum context length is 4096 tokens.","type":"BadRequestError","code":400}"#,
            #"{"error":"prompt is too long for the context window"}"#,
            #"{"detail":"Input is too long"}"#,
        ]
        for body in bodies {
            XCTAssertThrowsError(try ModelTranslation.decode(Data(body.utf8), status: 400)) { error in
                XCTAssertEqual((error as? TranslationFailure)?.shouldReduceChunk, true, body)
            }
        }
        let rateLimit = Data(#"{"error":{"message":"Too many tokens per minute"}}"#.utf8)
        XCTAssertThrowsError(try ModelTranslation.decode(rateLimit, status: 429)) { error in
            XCTAssertEqual((error as? TranslationFailure)?.shouldReduceChunk, false)
        }
    }

    func testHTTPErrorsShowTheServiceMessageWithTheKeyMasked() {
        let body = Data(#"{"error":{"message":"Incorrect API key provided: sk-secret-123.\n See docs.","code":"invalid_api_key"}}"#.utf8)
        XCTAssertThrowsError(try ModelTranslation.decode(body, status: 401, key: "sk-secret-123")) { error in
            guard case .http(401, let detail)? = error as? TranslationFailure else { return XCTFail("\(error)") }
            XCTAssertEqual(detail, "Incorrect API key provided: ••••. See docs.")
            XCTAssertFalse(error.localizedDescription.contains("sk-secret-123"))
            XCTAssertTrue(error.localizedDescription.contains("••••"))
        }
        XCTAssertThrowsError(try ModelTranslation.decode(Data("<html>Bad Gateway</html>".utf8), status: 502)) { error in
            guard case .http(502, nil)? = error as? TranslationFailure else { return XCTFail("\(error)") }
        }
        let long = ModelTranslation.displayedMessage(String(repeating: "a", count: 400), key: "")
        XCTAssertEqual(long?.count, 301)
        XCTAssertNil(ModelTranslation.displayedMessage(" \n ", key: ""))
    }
}

@MainActor
final class TranslationRunTests: XCTestCase {
    func testFailureRetainsProgressAndResumeSkipsCompletedParts() async {
        let run = TranslationRun(text: "First\n\nSecond\n\nThird")
        var requests: [String] = []
        await run.execute(id: run.begin()) { text in
            requests.append(text)
            if text == "Second" { throw TranslationFailure.http(429, detail: nil) }
            return text.uppercased()
        }
        XCTAssertEqual(run.phase, .failed)
        XCTAssertEqual(run.completed, 1)
        XCTAssertEqual(run.preview, "FIRST\n\n")
        XCTAssertFalse(run.isComplete)
        XCTAssertTrue(run.canContinue)
        await run.execute(id: run.begin()) { text in requests.append(text); return text.uppercased() }
        XCTAssertEqual(requests, ["First", "Second", "Second", "Third"])
        XCTAssertEqual(run.preview, "FIRST\n\nSECOND\n\nTHIRD")
        XCTAssertEqual(run.completed, 3)
        XCTAssertTrue(run.isComplete)
    }

    func testConcurrentPartsOverlapAndApplyInOrder() async {
        let run = TranslationRun(text: "One\n\nTwo\n\nThree\n\nFour")
        var active = 0, peak = 0
        await run.execute(id: run.begin(), concurrency: 3) { text in
            active += 1; peak = max(peak, active)
            try await Task.sleep(for: .milliseconds(text == "One" ? 30 : 5))
            active -= 1
            if text == "Three" { throw TranslationFailure.http(429, detail: nil) }
            return text.uppercased()
        }
        XCTAssertEqual(peak, 3)
        XCTAssertEqual(run.phase, .failed)
        XCTAssertEqual(run.completed, 2)
        XCTAssertEqual(run.preview, "ONE\n\nTWO\n\n")
        await run.execute(id: run.begin(), concurrency: 3) { $0.uppercased() }
        XCTAssertEqual(run.preview, "ONE\n\nTWO\n\nTHREE\n\nFOUR")
        XCTAssertTrue(run.isComplete)
    }

    func testExcerptFollowsPreviewAndResetClearsIt() async {
        let run = TranslationRun(text: "First\n\nSecond")
        XCTAssertEqual(run.excerpt.text, "")
        await run.execute(id: run.begin()) { $0.uppercased() }
        XCTAssertEqual(run.excerpt.text, run.preview)
        XCTAssertEqual(run.preview, "FIRST\n\nSECOND")
        run.reset()
        XCTAssertEqual(run.preview, "")
        XCTAssertEqual(run.excerpt.text, "")
    }

    func testCancellationDropsLateResultAndNewRunCanResume() async {
        let run = TranslationRun(text: "First\n\nSecond")
        await run.execute(id: run.begin()) { text in
            if text == "Second" { run.cancel() }
            return text.uppercased()
        }
        XCTAssertEqual(run.phase, .paused)
        XCTAssertEqual(run.completed, 1)
        XCTAssertEqual(run.preview, "FIRST\n\n")
        await run.execute(id: run.begin()) { $0.uppercased() }
        XCTAssertEqual(run.preview, "FIRST\n\nSECOND")
        XCTAssertTrue(run.isComplete)
    }

    func testOldRunCannotReplaceResultsFromNewRun() async {
        let run = TranslationRun(text: "First")
        await run.execute(id: run.begin()) { _ in
            run.reset()
            await run.execute(id: run.begin()) { _ in "New translation" }
            return "Stale translation"
        }
        XCTAssertEqual(run.preview, "New translation")
        XCTAssertTrue(run.isComplete)
    }

    func testSizeErrorSubdividesOnlyFailedPartAndDoesNotPublishTruncation() async {
        let long = String(repeating: "x", count: 600)
        let run = TranslationRun(text: "First\n\n" + long)
        var requests: [String] = []
        await run.execute(id: run.begin()) { text in
            requests.append(text)
            if text.count > 300 { throw TranslationFailure.truncated }
            return text.uppercased()
        }
        XCTAssertEqual(requests.map(\.count), [5, 600, 300, 300])
        XCTAssertEqual(run.preview, "FIRST\n\n" + long.uppercased())
        XCTAssertTrue(run.isComplete)
        XCTAssertEqual(run.total, 3)
    }

    func testTimeoutRetainsEarlierPartsAndIgnoresEventualResponse() async {
        let run = TranslationRun(text: "First\n\nSecond", timeout: .milliseconds(5))
        await run.execute(id: run.begin()) { text in
            if text == "Second" { try await Task.sleep(for: .milliseconds(50)) }
            return text.uppercased()
        }
        XCTAssertEqual(run.phase, .failed)
        XCTAssertEqual(run.completed, 1)
        XCTAssertEqual(run.preview, "FIRST\n\n")
        XCTAssertNotNil(run.error)
        XCTAssertFalse(run.isRunning)
    }

    func testRequestTimeoutSplitsThePartForTheNextAttemptWithoutRetryingAtOnce() async {
        let long = String(repeating: "x", count: 600)
        let run = TranslationRun(text: "First\n\n" + long)
        var requests: [String] = []
        await run.execute(id: run.begin()) { text in
            requests.append(text)
            if text.count > 300 { throw TranslationFailure.timeout }
            return text.uppercased()
        }
        XCTAssertEqual(requests.map(\.count), [5, 600])
        XCTAssertEqual(run.phase, .failed)
        XCTAssertEqual(run.total, 3)
        await run.execute(id: run.begin()) { text in requests.append(text); return text.uppercased() }
        XCTAssertEqual(requests.map(\.count), [5, 600, 300, 300])
        XCTAssertEqual(run.preview, "FIRST\n\n" + long.uppercased())
        XCTAssertTrue(run.isComplete)
    }

    func testWatchdogBacksUpTheModelRequestTimeout() throws {
        let request = try ModelTranslation.request(text: "Hi", source: nil, target: "ko", preferences: {
            var p = TranslationPreferences(); p.endpoint = "https://api.example.com/v1/chat/completions"; p.model = "m"; return p
        }(), key: "")
        XCTAssertEqual(request.timeoutInterval, ModelTranslation.requestTimeout)
        XCTAssertGreaterThan(TranslationRun.defaultTimeout, .seconds(ModelTranslation.requestTimeout))
    }

    func testPreparationFailureAndResetCannotLeakPriorOutput() async {
        let run = TranslationRun(text: "First\n\nSecond")
        await run.execute(id: run.begin(), prepare: { throw TranslationFailure.unsupported }) { _ in
            XCTFail("Preparation should prevent translation"); return ""
        }
        XCTAssertEqual(run.phase, .failed)
        XCTAssertEqual(run.completed, 0)
        await run.execute(id: run.begin()) { text in
            if text == "Second" { throw TranslationFailure.empty }
            return "Translated"
        }
        XCTAssertEqual(run.completed, 1)
        run.reset()
        XCTAssertEqual(run.phase, .idle)
        XCTAssertEqual(run.completed, 0)
        XCTAssertEqual(run.preview, "")
    }
}
