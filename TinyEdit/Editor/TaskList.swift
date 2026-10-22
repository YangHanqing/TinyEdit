import Foundation

/// GFM task list items (`- [ ] open`, `- [x] done`): the line parser shared by Toggle Task, Return continuation
/// and Markdown coloring, and the pure edits behind the first two.
enum TaskList {
    typealias Edit = IndentEditing.Edit
    typealias LineEdits = IndentEditing.LineEdits

    struct Item: Equatable {
        /// First non-blank character, where the marker starts.
        var markerStart: Int
        /// `-`, `*`, `+`, or digits followed by `.` or `)`.
        var marker: NSRange
        /// The three characters `[ ]`, `[x]` or `[X]`; nil for a list item without a box.
        var box: NSRange?
        var done: Bool
        /// Where the item's text starts: after the box and one blank, or after the marker's blanks.
        var contentStart: Int
    }

    struct Counts: Equatable, Sendable {
        var done: Int
        var total: Int
    }

    /// Languages where Toggle Task, box clicks and the status-bar count work. Only Markdown colors tasks,
    /// continues them on Return and skips fenced code.
    static func supports(_ language: EditorLanguage) -> Bool { language == .markdown || language == .plain }
    static func continuesOnReturn(_ language: EditorLanguage) -> Bool { language == .markdown }

    /// The list item on `line` (a line without its newline). `char` reads one UTF-16 unit.
    static func item(char: (Int) -> UInt16, line: NSRange) -> Item? {
        let end = NSMaxRange(line)
        var i = line.location
        while i < end, isBlank(char(i)) { i += 1 }
        let markerStart = i
        guard i < end else { return nil }
        let c = char(i)
        if c == 0x2D || c == 0x2A || c == 0x2B {   // - * +
            i += 1
        } else {
            var digits = 0
            while i < end, digits < 9, isDigit(char(i)) { i += 1; digits += 1 }
            guard digits > 0, i < end, char(i) == 0x2E || char(i) == 0x29 else { return nil }   // . )
            i += 1
        }
        let marker = NSRange(location: markerStart, length: i - markerStart)
        guard i < end, isBlank(char(i)) else { return nil }
        while i < end, isBlank(char(i)) { i += 1 }
        if i + 3 <= end, char(i) == 0x5B, char(i + 2) == 0x5D {   // [ ]
            let mid = char(i + 1)
            if mid == 0x20 || mid == 0x78 || mid == 0x58, i + 3 == end || isBlank(char(i + 3)) {
                let contentStart = i + 3 < end ? i + 4 : end
                return Item(markerStart: markerStart, marker: marker, box: NSRange(location: i, length: 3),
                            done: mid != 0x20, contentStart: contentStart)
            }
        }
        return Item(markerStart: markerStart, marker: marker, box: nil, done: false, contentStart: i)
    }

    static func item(in text: NSString, line: NSRange) -> Item? {
        item(char: { text.character(at: $0) }, line: line)
    }

    // MARK: Toggle Task

    /// Makes the touched non-blank lines tasks; when they all are, ticks them all, or unticks them all when
    /// none is open. With only blank lines, the caret's line becomes a task.
    static func toggle(in text: NSString, selection: NSRange) -> LineEdits {
        var lines = LineEditing.contentLines(in: text, selection: selection)
            .filter { LineEditing.firstNonBlank(text, $0) < NSMaxRange($0) }
        if lines.isEmpty { lines = [LineEditing.contentLines(in: text, selection: selection)[0]] }
        let items = lines.map { item(in: text, line: $0) }
        var edits: [Edit] = []
        if items.allSatisfy({ $0?.box != nil }) {
            let done = items.contains { $0?.done == false }
            for case let item? in items where item.done != done {
                edits.append(Edit(range: NSRange(location: item.box!.location + 1, length: 1), string: done ? "x" : " "))
            }
            // One character for one: the selection stays (`mapped` only knows insertions and deletions).
            return LineEdits(edits: edits, selection: selection)
        } else {
            for (line, item) in zip(lines, items) where item?.box == nil {
                if let item {
                    edits.append(Edit(range: NSRange(location: item.contentStart, length: 0), string: "[ ] "))
                } else {
                    edits.append(Edit(range: NSRange(location: LineEditing.firstNonBlank(text, line), length: 0), string: "- [ ] "))
                }
            }
        }
        return LineEdits(edits: edits, selection: IndentEditing.mapped(selection, through: edits))
    }

    // MARK: Box clicks

    /// The task whose box sits on `line`, if a click there may flip it: not in a Markdown fence.
    static func clickableItem(in text: NSString, line: NSRange, language: EditorLanguage) -> Item? {
        guard supports(language), let item = item(in: text, line: line), item.box != nil else { return nil }
        if language == .markdown, MarkdownFence.isInside(text, lineStart: line.location) { return nil }
        return item
    }

    /// The one-character edit a click on the box makes.
    static func flip(_ item: Item) -> Edit {
        Edit(range: NSRange(location: item.box!.location + 1, length: 1), string: item.done ? " " : "x")
    }

    // MARK: Counts

    /// Done and total task items, outside fences in Markdown. Nil when there are none or the language has no tasks.
    static func counts(in text: String, language: EditorLanguage) -> Counts? {
        guard supports(language) else { return nil }
        let u = Array(text.utf16)
        var counts = Counts(done: 0, total: 0)
        var fence: UInt16?
        var i = 0
        while i < u.count {
            var e = i
            while e < u.count, u[e] != 0x0A { e += 1 }
            let line = NSRange(location: i, length: e - i)
            let wasOpen = fence
            if language == .markdown { fence = MarkdownFence.state(after: line, open: fence) { u[$0] } }
            if wasOpen == nil, fence == nil, let item = item(char: { u[$0] }, line: line), item.box != nil {
                counts.total += 1
                if item.done { counts.done += 1 }
            }
            i = e + 1
        }
        return counts.total > 0 ? counts : nil
    }

    // MARK: Return

    /// Return in a task item after its box: a new open item below with the same indent and marker (an ordered
    /// marker counts up). On an item with nothing after the box, the line is cleared instead. Nil leaves
    /// Return to the usual newline.
    static func newline(in text: NSString, selection: NSRange) -> Edit? {
        guard selection.length == 0 else { return nil }
        let full = text.lineRange(for: NSRange(location: selection.location, length: 0))
        var end = NSMaxRange(full)
        if end > full.location, text.character(at: end - 1) == 0x0A { end -= 1 }
        let line = NSRange(location: full.location, length: end - full.location)
        guard let item = item(in: text, line: line), let box = item.box, selection.location >= NSMaxRange(box) else { return nil }
        if LineEditing.firstNonBlank(text, NSRange(location: item.contentStart, length: end - item.contentStart)) == end {
            return Edit(range: line, string: "")
        }
        let indent = text.substring(with: NSRange(location: line.location, length: item.markerStart - line.location))
        return Edit(range: selection, string: "\n" + indent + nextMarker(text.substring(with: item.marker)) + " [ ] ")
    }

    /// `-` stays `-`; `9.` becomes `10.`.
    private static func nextMarker(_ marker: String) -> String {
        guard marker.count > 1, let n = Int(marker.dropLast()) else { return marker }
        return String(n + 1) + String(marker.last!)
    }

    private static func isBlank(_ u: UInt16) -> Bool { u == 0x20 || u == 0x09 }
    private static func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }
}
