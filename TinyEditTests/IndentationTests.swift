import XCTest
import AppKit
@testable import TinyEdit

@MainActor
final class IndentationTests: XCTestCase {
    // MARK: Detection

    func testDetectsTabs() {
        XCTAssertEqual(IndentDetector.detect("all:\n\tcc a.c\n\tcc b.c\n"), .tabs)
    }

    func testDetectsTwoAndFourSpaces() {
        XCTAssertEqual(IndentDetector.detect("a:\n  b:\n    c: 1\n  d: 2\n"), .spaces(2))
        XCTAssertEqual(IndentDetector.detect("def f():\n    if x:\n        pass\n    return 1\n"), .spaces(4))
    }

    func testNothingIndentedIsNil() {
        XCTAssertNil(IndentDetector.detect("one\ntwo\n\nthree"))
        XCTAssertNil(IndentDetector.detect(""))
    }

    func testBlockCommentContinuationsAreIgnored() {
        let c = "/**\n * doc\n * more\n */\nint f() {\n    return 0;\n}\n"
        XCTAssertEqual(IndentDetector.detect(c), .spaces(4))
    }

    func testFormatRulesOverrideDetection() {
        XCTAssertEqual(IndentStyle.resolve(detected: .spaces(4), language: .makefile, preferred: .spaces(4)), .tabs)
        XCTAssertEqual(IndentStyle.resolve(detected: .tabs, language: .yaml, preferred: .spaces(2)), .spaces(2))
        XCTAssertEqual(IndentStyle.resolve(detected: nil, language: .yaml, preferred: .tabs), .spaces(2))
        XCTAssertEqual(IndentStyle.resolve(detected: nil, language: .go, preferred: .spaces(4)), .tabs)
    }

    func testLanguageConventionsFillInOnlyWithoutDetection() {
        XCTAssertEqual(IndentStyle.resolve(detected: nil, language: .python, preferred: .spaces(2)), .spaces(4))
        XCTAssertEqual(IndentStyle.resolve(detected: nil, language: .python, preferred: .tabs), .spaces(4))
        XCTAssertEqual(IndentStyle.resolve(detected: .spaces(2), language: .python, preferred: .spaces(4)), .spaces(2))
        XCTAssertEqual(IndentStyle.resolve(detected: .spaces(2), language: .go, preferred: .spaces(4)), .spaces(2))
        XCTAssertEqual(IndentStyle.resolve(detected: nil, language: .javascript, preferred: .tabs), .tabs)
        XCTAssertEqual(IndentStyle.resolve(detected: .spaces(2), language: .plain, preferred: .tabs), .spaces(2))
    }

    func testPreferredIndentFollowsSettings() {
        var s = EditorSettings()
        XCTAssertEqual(s.preferredIndent, .spaces(4))
        s.tabWidth = 2
        XCTAssertEqual(s.preferredIndent, .spaces(2))
        s.insertSpaces = false
        XCTAssertEqual(s.preferredIndent, .tabs)
    }

    func testIndentSettingsRoundTrip() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "IndentationTests.\(UUID())"))
        var s = EditorSettings()
        s.insertSpaces = false
        s.detectIndentation = false
        s.save(to: d)
        let loaded = EditorSettings.load(from: d)
        XCTAssertFalse(loaded.insertSpaces)
        XCTAssertFalse(loaded.detectIndentation)
        XCTAssertTrue(EditorSettings.load(from: UserDefaults(suiteName: "IndentationTests.\(UUID())")!).detectIndentation)
    }

    func testJSONMarkSettingsRoundTrip() throws {
        let fresh = EditorSettings.load(from: try XCTUnwrap(UserDefaults(suiteName: "IndentationTests.\(UUID())")))
        XCTAssertEqual(fresh.decorationOptions.jsonMarks, JSONMarkOptions())                    // all on
        let d = try XCTUnwrap(UserDefaults(suiteName: "IndentationTests.\(UUID())"))
        var s = EditorSettings()
        s.jsonMarkJWTExpiry = false
        s.jsonMarkSizes = false
        s.save(to: d)
        var expected = JSONMarkOptions()
        expected.jwtExpiry = false
        expected.sizes = false
        XCTAssertEqual(EditorSettings.load(from: d).decorationOptions.jsonMarks, expected)
    }

    // MARK: Pure edits

    func testNewlineKeepsIndent() {
        let t = "    foo" as NSString
        let e = IndentEditing.newline(in: t, selection: NSRange(location: 7, length: 0))
        XCTAssertEqual(e, .init(range: NSRange(location: 7, length: 0), string: "\n    "))
    }

    func testNewlineInsideLeadingWhitespaceCopiesOnlyUpToCaret() {
        let t = "x\n\t  foo" as NSString
        let e = IndentEditing.newline(in: t, selection: NSRange(location: 4, length: 0))
        XCTAssertEqual(e.string, "\n\t ")
    }

    func testNewlineOnBlankLineMovesIndentDown() {
        let t = "a\n    " as NSString
        let e = IndentEditing.newline(in: t, selection: NSRange(location: 6, length: 0))
        XCTAssertEqual(e, .init(range: NSRange(location: 2, length: 4), string: "\n    "))
    }

    func testNewlineReplacesSelection() {
        let t = "  abc def" as NSString
        let e = IndentEditing.newline(in: t, selection: NSRange(location: 5, length: 1))
        XCTAssertEqual(e, .init(range: NSRange(location: 5, length: 1), string: "\n  "))
    }

    func testTabInsertsToNextStopInLeadingWhitespace() {
        let t = "  ab" as NSString
        XCTAssertEqual(IndentEditing.tab(in: t, selection: NSRange(location: 2, length: 0), style: .spaces(4), tabWidth: 4), "  ")
        XCTAssertEqual(IndentEditing.tab(in: t, selection: NSRange(location: 0, length: 0), style: .spaces(2), tabWidth: 4), "  ")
        let withTab = "\tx" as NSString   // TAB counts as tabWidth columns
        XCTAssertEqual(IndentEditing.tab(in: withTab, selection: NSRange(location: 1, length: 0), style: .spaces(3), tabWidth: 8), " ")
        XCTAssertEqual(IndentEditing.tab(in: t, selection: NSRange(location: 3, length: 0), style: .tabs, tabWidth: 4), "\t")
    }

    func testTabAfterTextInsertsFullWidth() {
        let t = "abc" as NSString
        XCTAssertEqual(IndentEditing.tab(in: t, selection: NSRange(location: 3, length: 0), style: .spaces(4), tabWidth: 4), "    ")
        XCTAssertEqual(IndentEditing.tab(in: "  ab" as NSString, selection: NSRange(location: 4, length: 0), style: .spaces(4), tabWidth: 4), "    ")
        XCTAssertEqual(IndentEditing.tab(in: "中" as NSString, selection: NSRange(location: 1, length: 0), style: .spaces(4), tabWidth: 4), "    ")
        XCTAssertEqual(IndentEditing.tab(in: "👍" as NSString, selection: NSRange(location: 2, length: 0), style: .spaces(2), tabWidth: 4), "  ")
    }

    func testSelectionSpansLines() {
        let t = "ab\ncd" as NSString
        XCTAssertFalse(IndentEditing.selectionSpansLines(in: t, selection: NSRange(location: 0, length: 2)))
        XCTAssertTrue(IndentEditing.selectionSpansLines(in: t, selection: NSRange(location: 1, length: 2)))
        XCTAssertFalse(IndentEditing.selectionSpansLines(in: t, selection: NSRange(location: 2, length: 0)))
    }

    private func applying(_ change: IndentEditing.LineEdits, to text: String) -> String {
        let m = NSMutableString(string: text)
        for e in change.edits.reversed() { m.replaceCharacters(in: e.range, with: e.string) }
        return m as String
    }

    func testIndentLinesSkipsEmptyLinesAndKeepsSelection() {
        let text = "a\n\n  b\nc"
        let sel = NSRange(location: 0, length: 6)   // "a\n\n  b", last line untouched
        let change = IndentEditing.indentLines(in: text as NSString, selection: sel, style: .spaces(4), tabWidth: 4)
        let out = applying(change, to: text)
        XCTAssertEqual(out, "    a\n\n    b\nc")   // "  b" snaps to the next stop
        XCTAssertEqual((out as NSString).substring(with: change.selection), "    a\n\n    b")
    }

    func testIndentLinesWithTabsAndSelectionEndingAtLineStart() {
        let text = "a\nb\nc"
        let change = IndentEditing.indentLines(in: text as NSString, selection: NSRange(location: 0, length: 4),
                                               style: .tabs, tabWidth: 4)
        let out = applying(change, to: text)
        XCTAssertEqual(out, "\ta\n\tb\nc")
        XCTAssertEqual((out as NSString).substring(with: change.selection), "\ta\n\tb\n")
    }

    func testIndentLinesMidLineSelectionShifts() {
        let text = "abc\ndef"
        let change = IndentEditing.indentLines(in: text as NSString, selection: NSRange(location: 1, length: 4),
                                               style: .spaces(2), tabWidth: 4)
        let out = applying(change, to: text)
        XCTAssertEqual(out, "  abc\n  def")
        XCTAssertEqual((out as NSString).substring(with: change.selection), "bc\n  d")
    }

    func testOutdentLines() {
        let text = "      a\n\tb\n  c\nd"
        let change = IndentEditing.outdentLines(in: text as NSString, selection: NSRange(location: 0, length: (text as NSString).length),
                                                style: .spaces(4), tabWidth: 4)
        XCTAssertEqual(applying(change, to: text), "    a\nb\nc\nd")   // 6 -> 4, TAB removed, 2 -> 0, none
        let caret = IndentEditing.outdentLines(in: "    x" as NSString, selection: NSRange(location: 5, length: 0),
                                               style: .tabs, tabWidth: 4)
        XCTAssertEqual(applying(caret, to: "    x"), "x")
        XCTAssertEqual(caret.selection, NSRange(location: 1, length: 0))
        XCTAssertTrue(IndentEditing.outdentLines(in: "x" as NSString, selection: NSRange(location: 0, length: 0),
                                                 style: .spaces(4), tabWidth: 4).edits.isEmpty)
    }

    func testSoftTabDeletion() {
        let t = "x\n      y" as NSString
        XCTAssertEqual(IndentEditing.softTabDeletion(in: t, caret: 8, style: .spaces(4)), NSRange(location: 6, length: 2))
        XCTAssertEqual(IndentEditing.softTabDeletion(in: t, caret: 6, style: .spaces(4)), NSRange(location: 2, length: 4))
        XCTAssertNil(IndentEditing.softTabDeletion(in: t, caret: 9, style: .spaces(4)))   // after "y"
        XCTAssertNil(IndentEditing.softTabDeletion(in: t, caret: 8, style: .tabs))
        XCTAssertNil(IndentEditing.softTabDeletion(in: t, caret: 2, style: .spaces(4)))   // line start
        XCTAssertNil(IndentEditing.softTabDeletion(in: "\t  y" as NSString, caret: 3, style: .spaces(4)))
    }

    // MARK: Text view

    private func makeHost(text: String) -> (EditorTextHost, BufferTextStore, NSWindow) {
        let settings = EditorSettings()
        let host = EditorTextHost()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host.scrollView
        let store = BufferTextStore(id: UUID(), text: text, settings: settings)
        host.activate(store, settings: settings)
        return (host, store, window)
    }

    func testReturnKeepsIndentAndUndoesInOneStep() {
        let (host, store, _) = makeHost(text: "if x:\n    y = 1")
        host.textView.setSelectedRange(NSRange(location: store.length, length: 0))
        host.textView.insertNewline(nil)
        XCTAssertEqual(store.logicalString(), "if x:\n    y = 1\n    ")
        XCTAssertEqual(host.textView.selectedRange(), NSRange(location: store.length, length: 0))
        host.textView.insertNewline(nil)
        XCTAssertEqual(store.logicalString(), "if x:\n    y = 1\n\n    ")
    }

    func testTabFollowsResolvedStyle() {
        let (host, store, _) = makeHost(text: "all:\n")
        host.textView.setSelectedRange(NSRange(location: store.length, length: 0))
        host.textView.indentStyle = { .tabs }
        host.textView.insertTab(nil)
        XCTAssertEqual(store.logicalString(), "all:\n\t")
        host.textView.indentStyle = { .spaces(2) }
        host.textView.insertText("x", replacementRange: host.textView.selectedRange())
        host.textView.insertTab(nil)
        XCTAssertEqual(store.logicalString(), "all:\n\tx  ")   // after text: the full width of 2
    }

    func testTabOverLinesIndentsAndUndoesInOneStep() {
        let (host, store, _) = makeHost(text: "a\nb\nc")
        host.textView.indentStyle = { .spaces(2) }
        host.textView.setSelectedRange(NSRange(location: 0, length: 3))
        host.textView.insertTab(nil)
        XCTAssertEqual(store.logicalString(), "  a\n  b\nc")
        XCTAssertEqual(host.textView.selectedRange(), NSRange(location: 0, length: 7))
        host.textView.undoManager?.undo()
        XCTAssertEqual(store.logicalString(), "a\nb\nc")
    }

    func testShiftTabOutdentsTouchedLines() {
        let (host, store, _) = makeHost(text: "  a\n  b\nc")
        host.textView.indentStyle = { .spaces(2) }
        host.textView.setSelectedRange(NSRange(location: 3, length: 3))   // from after "a" into "  b"
        host.textView.insertBacktab(nil)
        XCTAssertEqual(store.logicalString(), "a\nb\nc")
        XCTAssertEqual(host.textView.selectedRange(), NSRange(location: 1, length: 1))
    }

    func testTabInsideOneLineStillReplacesSelection() {
        let (host, store, _) = makeHost(text: "abcd")
        host.textView.indentStyle = { .spaces(4) }
        host.textView.setSelectedRange(NSRange(location: 1, length: 2))
        host.textView.insertTab(nil)
        XCTAssertEqual(store.logicalString(), "a    d")
    }

    func testBackspaceDeletesOneIndentLevel() {
        let (host, store, _) = makeHost(text: "        x")
        host.textView.indentStyle = { .spaces(4) }
        host.textView.setSelectedRange(NSRange(location: 8, length: 0))
        host.textView.deleteBackward(nil)
        XCTAssertEqual(store.logicalString(), "    x")
        host.textView.setSelectedRange(NSRange(location: 5, length: 0))
        host.textView.deleteBackward(nil)
        XCTAssertEqual(store.logicalString(), "    ")
    }

    func testStoreDetectsIndentWithLineIndex() async throws {
        let store = BufferTextStore(id: UUID(), text: "a\n\tb\n\tc\n", settings: EditorSettings())
        let done = expectation(description: "line index")
        store.onLineIndexUpdated = { done.fulfill() }
        store.scheduleLineIndex(delay: .zero)
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(store.detectedIndent, .tabs)
    }
}
