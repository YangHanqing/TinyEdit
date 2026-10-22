import XCTest
@testable import TinyEdit

final class ContentLanguageDetectionTests: XCTestCase {
    func testClearLanguageSignals() {
        let cases: [(String, EditorLanguage)] = [
            ("#!/usr/bin/env node\nconsole.log('hi')", .javascript),
            ("{\"name\": \"TinyEdit\", \"enabled\": true}", .json),
            ("# Notes\n\n- First item", .markdown),
            ("```javascript\nconst n = 1;\n```", .markdown),
            ("```python\ndef greet():\n    pass\n```", .markdown),
            ("function greet(name) {\n console.log(name);\n}", .javascript),
            ("interface Person {\n name: string;\n}", .typescript),
            ("def greet(name):\n    print(name)", .python),
            ("<!DOCTYPE html>\n<html></html>", .html),
            ("<?xml version=\"1.0\"?><root/>", .xml),
            ("SELECT name FROM users;", .sql),
            ("FROM alpine\nRUN echo hello", .dockerfile),
            ("import Foundation\nfunc greet() { print(1) }", .swift),
            ("package main\nfunc main() {}", .go),
            ("fn main() { println!(\"hi\"); }", .rust),
            // Signatures that used to be missed.
            ("{\n  // compiler options\n  \"strict\": true,\n}", .json),
            ("{\"a\": 1}\n{\"a\": 2}", .json),
            ("import os\nfor name in os.listdir('.'):\n    print(name)", .python),
            ("# Load\nresult = handlers[name](df)\nfor row in df:\n    print(row)", .python),
            ("type User = {\n  id: number;\n};", .typescript),
            ("export const add = (a, b) => a + b;", .javascript),
            ("SELECT id,\n       name\nFROM users\nWHERE active = 1;", .sql),
            ("UPDATE users SET name = 'b' WHERE id = 1;", .sql),
            ("<div class=\"card\">\n  <p>Hi</p>\n</div>", .html),
            ("<project>\n  <version>1</version>\n</project>", .xml),
            ("<?php\necho 'hi';", .php),
            ("# Compose\nservices:\n  web:\n    ports:\n      - \"80:80\"", .yaml),
            ("[package]\nname = \"tinyedit\"\nversion = \"0.1.0\"", .toml),
            ("[core]\n\tbare = false", .ini),
            (".card {\n  color: red;\n  margin: 0;\n}", .css),
            ("brew install xcodegen\ncd TinyEdit\nxcodegen generate", .shell),
            ("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b", .diff),
            ("build:\n\tswift build\n\n.PHONY: build", .makefile),
            ("#include <stdio.h>\nint main(void) { return 0; }", .c),
            ("#include <iostream>\nint main() { std::cout << 1; }", .cpp),
            ("public class Main {\n  public static void main(String[] a) {}\n}", .java),
            ("using System;\nclass P { static void Main() {} }", .csharp),
            ("fun main() {\n  println(\"hi\")\n}", .kotlin),
            ("struct ContentView: View {\n  var body: some View { Text(\"x\") }\n}", .swift),
            ("func main() {\n\tx := 1\n\tfmt.Println(x)\n}", .go),
            ("def greet(name)\n  puts name\nend", .ruby),
            ("local function f()\n  return 1\nend", .lua),
            ("$n = 1\nWrite-Host $n", .powershell),
        ]
        for (text, language) in cases {
            XCTAssertEqual(ContentLanguageDetector.detect(text), language, text)
        }
    }

    func testAmbiguousAndIncompleteTextDoesNotGuess() {
        let notes = ["", "  \n", "# A heading", "- One item", "Hello world", "const n = 1;", "{\"unfinished\":",
                     "Select the best option from the list below.", "Todo: buy milk\nNote: call mom",
                     "Ingredients:\n  flour: 200g\n  sugar: 100g", "x = 5\ny = 6", "Make sure the cat is fed.\nCall the vet.",
                     "Remember to buy:\n- milk\n- eggs", "From: Alice\nTo: Bob\n\nLunch?", "1. Wake up\n2. Coffee",
                     "今天的会议记录：\n1. 讨论预算\n2. 确定上线时间", "[x] fix bug\n[ ] write tests"]
        for text in notes {
            XCTAssertNil(ContentLanguageDetector.detect(text), text)
        }
    }

    /// Only the first 32 KB is sampled, so long JSON must be recognised from a valid prefix.
    func testTruncatedSamples() {
        let big = "[" + (0..<2000).map { "{\"id\": \($0), \"name\": \"item\"}" }.joined(separator: ",\n") + "]"
        XCTAssertGreaterThan(big.utf16.count, ContentLanguageDetector.sampleLimit)
        XCTAssertEqual(ContentLanguageDetector.detect(big, isComplete: false), .json)
        XCTAssertNil(ContentLanguageDetector.detect("{\"unfinished\":", isComplete: true))
        XCTAssertFalse(ContentLanguageDetector.isJSON("{\"a\": 1, oops", isComplete: false))
        XCTAssertFalse(ContentLanguageDetector.isJSON("[link](https://x)", isComplete: true))
        XCTAssertFalse(ContentLanguageDetector.isJSON("{\"a\": True}", isComplete: true))
        let python = (["import os", "for name in os.listdir('.'):"] + Array(repeating: "    print(name)  # \u{4F60}\u{597D}", count: 2000)).joined(separator: "\n")
        XCTAssertEqual(ContentLanguageDetector.detect(python, isComplete: false), .python)
    }

    func testSuggestionMetadataRoundTripAndOldSessionCompatibility() throws {
        var buffer = EditorBuffer(title: "Untitled")
        buffer.languageSuggestion = .markdown
        buffer.languageDetectionSuppressed = true
        let data = try JSONEncoder().encode(BufferMetadata(buffer))
        let restored = try XCTUnwrap(JSONDecoder().decode(BufferMetadata.self, from: data).makeBuffer())
        XCTAssertEqual(restored.languageSuggestion, .markdown)
        XCTAssertTrue(restored.languageDetectionSuppressed)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "languageSuggestion")
        legacy.removeValue(forKey: "languageDetectionSuppressed")
        let metadata = try JSONDecoder().decode(BufferMetadata.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(try XCTUnwrap(metadata.makeBuffer()).languageDetectionSuppressed)
    }

    @MainActor
    func testDismissApplyAndManualRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppState(root: root, autoRestore: false)
        await app.restore()
        let store = try XCTUnwrap(app.activeStore)
        store.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# Notes\n- Item")
        app.scheduleLanguageDetection(store.id, delay: .zero)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(app.selectedBuffer?.languageSuggestion, .markdown)
        XCTAssertEqual(app.selectedBuffer?.language, .plain)
        app.dismissLanguageSuggestion()
        store.textStorage.replaceCharacters(in: NSRange(location: store.length, length: 0), with: "\n- Another")
        app.scheduleLanguageDetection(store.id, delay: .zero)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(app.selectedBuffer?.languageSuggestion)
        app.detectLanguageFromContent()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(app.selectedBuffer?.languageSuggestion, .markdown)
        app.setLanguage(.markdown)
        XCTAssertNil(app.selectedBuffer?.languageSuggestion)
        XCTAssertEqual(app.selectedBuffer?.language, .markdown)
        app.setLanguage(.plain)
        app.scheduleLanguageDetection(store.id, delay: .zero)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(app.selectedBuffer?.languageSuggestion)
        XCTAssertTrue(app.selectedBuffer?.languageDetectionSuppressed == true)
        await app.performFlush()
    }

    /// Until the user acts, the suggestion tracks the text instead of keeping the first guess.
    @MainActor
    func testSuggestionFollowsTheText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppState(root: root, autoRestore: false)
        await app.restore()
        let store = try XCTUnwrap(app.activeStore)
        func replaceText(_ text: String) async throws {
            store.textStorage.replaceCharacters(in: NSRange(location: 0, length: store.length), with: text)
            app.scheduleLanguageDetection(store.id, delay: .zero)
            try await Task.sleep(for: .milliseconds(150))
        }
        try await replaceText("# Notes\n- Item")
        XCTAssertEqual(app.selectedBuffer?.languageSuggestion, .markdown)
        try await replaceText("import os\nfor name in os.listdir('.'):\n    print(name)")
        XCTAssertEqual(app.selectedBuffer?.languageSuggestion, .python)
        try await replaceText("Hello")
        XCTAssertNil(app.selectedBuffer?.languageSuggestion)
        XCTAssertFalse(app.selectedBuffer?.languageDetectionSuppressed ?? true)
        try await replaceText("{\"a\": 1}")
        XCTAssertEqual(app.selectedBuffer?.languageSuggestion, .json)
        app.setLanguage(.json)
        app.detectLanguageFromContent()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(app.selectedBuffer?.languageSuggestion, "already JSON: nothing to suggest")
        await app.performFlush()
    }

    @MainActor
    func testEditsDebounceAndSavedFilesAreExcluded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppState(root: root, autoRestore: false)
        await app.restore()
        let store = try XCTUnwrap(app.activeStore)
        store.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# Notes\n- Item")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(app.selectedBuffer?.languageSuggestion)
        store.textStorage.replaceCharacters(in: NSRange(location: store.length, length: 0), with: "\n- Another")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(app.selectedBuffer?.languageSuggestion)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(app.selectedBuffer?.languageSuggestion, .markdown)
        app.session.buffers[store.id]?.languageSuggestion = nil
        app.session.buffers[store.id]?.languageDetectionSuppressed = false
        app.session.buffers[store.id]?.fileBookmark = Data([1])
        app.scheduleLanguageDetection(store.id, delay: .zero)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(app.selectedBuffer?.languageSuggestion)
        await app.performFlush()
    }
}
