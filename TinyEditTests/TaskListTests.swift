import XCTest
@testable import TinyEdit

@MainActor
final class TaskListTests: XCTestCase {
    private func caret(_ i: Int) -> NSRange { NSRange(location: i, length: 0) }

    private func item(_ line: String) -> TaskList.Item? {
        let ns = line as NSString
        return TaskList.item(in: ns, line: NSRange(location: 0, length: ns.length))
    }

    /// Applies the edits back to front, as the text view does.
    private func toggle(_ text: String, _ sel: NSRange) -> (String, NSRange) {
        let ns = NSMutableString(string: text)
        let change = TaskList.toggle(in: ns, selection: sel)
        for e in change.edits.reversed() { ns.replaceCharacters(in: e.range, with: e.string) }
        return (ns as String, change.selection)
    }

    private func newline(_ text: String, _ at: Int) -> String? {
        let ns = NSMutableString(string: text)
        guard let edit = TaskList.newline(in: ns, selection: caret(at)) else { return nil }
        ns.replaceCharacters(in: edit.range, with: edit.string)
        return ns as String
    }

    func testParse() {
        XCTAssertEqual(item("- [ ] a")?.box, NSRange(location: 2, length: 3))
        XCTAssertEqual(item("- [ ] a")?.done, false)
        XCTAssertEqual(item("- [ ] a")?.contentStart, 6)
        XCTAssertEqual(item("  * [x] a")?.done, true)
        XCTAssertEqual(item("+ [X] a")?.done, true)
        XCTAssertEqual(item("12. [ ] a")?.marker, NSRange(location: 0, length: 3))
        XCTAssertEqual(item("1) [ ] a")?.box, NSRange(location: 3, length: 3))
        XCTAssertEqual(item("- [ ]")?.contentStart, 5)
        XCTAssertNotNil(item("\t-\t[ ]\ta")?.box)
        // List items without a box, and things that are not list items.
        XCTAssertNil(item("- a")?.box)
        XCTAssertEqual(item("- a")?.contentStart, 2)
        XCTAssertNil(item("- [ ]a")?.box)
        XCTAssertNil(item("- [y] a")?.box)
        XCTAssertNil(item("-[ ] a"))
        XCTAssertNil(item("1.a"))
        XCTAssertNil(item("1234567890. [ ] a"))
        XCTAssertNil(item("[ ] a"))
        XCTAssertNil(item(""))
    }

    func testToggleMakesTasks() {
        XCTAssertEqual(toggle("buy milk", caret(3)).0, "- [ ] buy milk")
        XCTAssertEqual(toggle("buy milk", caret(3)).1, caret(9))
        XCTAssertEqual(toggle("- buy milk", caret(3)).0, "- [ ] buy milk")
        XCTAssertEqual(toggle("2. buy milk", caret(3)).0, "2. [ ] buy milk")
        // Each line keeps its own indent; blank lines are skipped.
        XCTAssertEqual(toggle("a\n\n  b", NSRange(location: 0, length: 6)).0, "- [ ] a\n\n  - [ ] b")
        // Mixed: only the lines that are not tasks change.
        XCTAssertEqual(toggle("- [x] a\nb", NSRange(location: 0, length: 9)).0, "- [x] a\n- [ ] b")
        // Only blank lines: the caret's line becomes a task.
        XCTAssertEqual(toggle("", caret(0)).0, "- [ ] ")
        XCTAssertEqual(toggle("", caret(0)).1, caret(6))
        XCTAssertEqual(toggle("  ", caret(2)).0, "  - [ ] ")
    }

    func testToggleTicks() {
        XCTAssertEqual(toggle("- [ ] a", caret(7)).0, "- [x] a")
        XCTAssertEqual(toggle("- [ ] a", caret(7)).1, caret(7))
        XCTAssertEqual(toggle("- [X] a", caret(0)).0, "- [ ] a")
        // Any open item ticks them all; all done unticks them all.
        XCTAssertEqual(toggle("- [x] a\n- [ ] b", NSRange(location: 0, length: 15)).0, "- [x] a\n- [x] b")
        XCTAssertEqual(toggle("- [x] a\n- [x] b", NSRange(location: 0, length: 15)).0, "- [ ] a\n- [ ] b")
        // A selection ending at a line start does not touch that line.
        XCTAssertEqual(toggle("- [ ] a\n- [ ] b", NSRange(location: 0, length: 8)).0, "- [x] a\n- [ ] b")
    }

    func testReturnContinues() {
        XCTAssertEqual(newline("- [x] a", 7), "- [x] a\n- [ ] ")
        XCTAssertEqual(newline("  * [ ] ab", 9), "  * [ ] a\n  * [ ] b")
        XCTAssertEqual(newline("9. [ ] a", 8), "9. [ ] a\n10. [ ] ")
        XCTAssertEqual(newline("1) [ ] a", 8), "1) [ ] a\n2) [ ] ")
        // An empty item ends the list.
        XCTAssertEqual(newline("- [ ] a\n  - [ ] \nz", 16), "- [ ] a\n\nz")
        // Before the box, on a plain list item, or on plain text: the usual newline.
        XCTAssertNil(newline("- [ ] a", 1))
        XCTAssertNil(newline("- a", 3))
        XCTAssertNil(newline("a", 1))
        let ns = "- [ ] ab" as NSString
        XCTAssertNil(TaskList.newline(in: ns, selection: NSRange(location: 6, length: 1)))
    }

    func testMarkdownColors() {
        let src = "- [ ] open `c`\n- [x] done `c`\n```\n- [x] fenced\n```\n"
        let ns = src as NSString
        let k = SyntaxHighlighter.spans(language: .markdown, text: src, limit: nil).map { (ns.substring(with: $0.range), $0.kind) }
        XCTAssertTrue(k.contains { $0.0 == "[ ]" && $0.1 == .taskBox })
        XCTAssertTrue(k.contains { $0.0 == "`c`" && $0.1 == .code })
        XCTAssertTrue(k.contains { $0.0 == "- [x] done `c`" && $0.1 == .taskDone })
        XCTAssertEqual(k.filter { $0.1 == .code && $0.0 == "`c`" }.count, 1)
        XCTAssertFalse(k.contains { $0.1 == .taskDone && $0.0.contains("fenced") })
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

    func testReturnInTextView() {
        let (host, store, _) = makeHost(text: "- [x] a")
        let tv = host.textView
        tv.setSelectedRange(caret(store.length))
        tv.insertNewline(nil)
        XCTAssertEqual(store.logicalString(), "- [x] a\n")   // not Markdown: no continuation
        tv.undoManager?.undo()
        tv.taskLanguage = { .markdown }
        tv.setSelectedRange(caret(store.length))
        tv.insertNewline(nil)
        XCTAssertEqual(store.logicalString(), "- [x] a\n- [ ] ")
        XCTAssertEqual(tv.selectedRange(), caret(store.length))
        tv.insertNewline(nil)
        XCTAssertEqual(store.logicalString(), "- [x] a\n")
        XCTAssertEqual(tv.selectedRange(), caret(8))
    }

    func testToggleTaskUndoesInOneStep() {
        let (host, store, _) = makeHost(text: "a\nb")
        host.textView.setSelectedRange(NSRange(location: 0, length: 3))
        host.textView.toggleTask()
        XCTAssertEqual(store.logicalString(), "- [ ] a\n- [ ] b")
        XCTAssertEqual(host.textView.selectedRange(), NSRange(location: 0, length: 15))
        host.textView.undoManager?.undo()
        XCTAssertEqual(store.logicalString(), "a\nb")
    }

    // MARK: Box clicks, counts, fences

    func testCountsSkipFencesInMarkdownOnly() {
        let text = "- [ ] a\n- [x] b\n```\n- [ ] in code\n~~~\n- [x] still code\n```\n* [X] c\nplain\n- d"
        XCTAssertEqual(TaskList.counts(in: text, language: .markdown), TaskList.Counts(done: 2, total: 3))
        XCTAssertEqual(TaskList.counts(in: text, language: .plain), TaskList.Counts(done: 3, total: 5))
        XCTAssertNil(TaskList.counts(in: text, language: .python))
        XCTAssertNil(TaskList.counts(in: "- a\nno tasks", language: .markdown))
        XCTAssertNil(TaskList.counts(in: "", language: .markdown))
    }

    func testFenceState() {
        let text = "a\n```\nb\n~~~\nc\n```\nd\n" as NSString
        XCTAssertFalse(MarkdownFence.isInside(text, lineStart: 0))
        XCTAssertTrue(MarkdownFence.isInside(text, lineStart: 6))    // b
        XCTAssertTrue(MarkdownFence.isInside(text, lineStart: 12))   // c: ~~~ does not close a ``` fence
        XCTAssertFalse(MarkdownFence.isInside(text, lineStart: 18))  // d
    }

    func testClickableItemAndFlip() {
        let text = "- [ ] a\n```\n- [ ] b\n```\n" as NSString
        let first = NSRange(location: 0, length: 7)
        let fenced = NSRange(location: 12, length: 7)
        XCTAssertNotNil(TaskList.clickableItem(in: text, line: first, language: .markdown))
        XCTAssertNil(TaskList.clickableItem(in: text, line: fenced, language: .markdown))
        XCTAssertNotNil(TaskList.clickableItem(in: text, line: fenced, language: .plain))
        XCTAssertNil(TaskList.clickableItem(in: text, line: first, language: .swift))
        XCTAssertNil(TaskList.clickableItem(in: "- a" as NSString, line: NSRange(location: 0, length: 3), language: .markdown))
        XCTAssertEqual(TaskList.flip(item("- [ ] a")!), .init(range: NSRange(location: 3, length: 1), string: "x"))
        XCTAssertEqual(TaskList.flip(item("  1. [X] a")!), .init(range: NSRange(location: 6, length: 1), string: " "))
    }

    func testClickOnBoxFlipsItAsOneUndoStep() {
        let (host, store, _) = makeHost(text: "- [ ] a\nb")
        let tv = host.textView
        tv.taskLanguage = { .markdown }
        tv.setSelectedRange(caret(9))
        guard let box = tv.segmentRect(NSRange(location: 2, length: 3)) else { return XCTFail("no layout") }
        let onBox = NSPoint(x: box.midX, y: box.midY)
        XCTAssertTrue(tv.flipTask(at: onBox))
        XCTAssertEqual(store.logicalString(), "- [x] a\nb")
        XCTAssertEqual(tv.selectedRange(), caret(9))   // the caret does not move
        tv.undoManager?.undo()
        XCTAssertEqual(store.logicalString(), "- [ ] a\nb")
        XCTAssertTrue(tv.flipTask(at: onBox))
        XCTAssertTrue(tv.flipTask(at: onBox))
        XCTAssertEqual(store.logicalString(), "- [ ] a\nb")
        // Beside the box, or in a language without tasks, a click is an ordinary click.
        XCTAssertFalse(tv.flipTask(at: NSPoint(x: box.maxX + 20, y: box.midY)))
        tv.taskLanguage = { .json }
        XCTAssertFalse(tv.flipTask(at: onBox))
        XCTAssertEqual(store.logicalString(), "- [ ] a\nb")
    }
}
