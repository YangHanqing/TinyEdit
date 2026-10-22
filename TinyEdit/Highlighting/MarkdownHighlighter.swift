import Foundation

enum MarkdownHighlighter {
    static func scan(_ u: [UInt16]) -> [HighlightSpan] {
        var out: [HighlightSpan] = []
        let n = u.count
        var i = 0
        var fence: UInt16?          // 0x60 backtick or 0x7E tilde while inside a fence
        while i < n {
            var e = i
            while e < n, u[e] != 0x0A { e += 1 }
            let lineEnd = e
            // first non-space run
            var p = i
            while p < lineEnd, u[p] == 0x20 || u[p] == 0x09 { p += 1 }
            let fenceChar = MarkdownFence.marker(char: { u[$0] }, line: NSRange(location: i, length: lineEnd - i))

            if let open = fence {
                out.append(HighlightSpan(range: NSRange(location: i, length: lineEnd - i), kind: .code))
                if fenceChar == open { fence = nil }
            } else if let f = fenceChar {
                fence = f
                out.append(HighlightSpan(range: NSRange(location: i, length: lineEnd - i), kind: .code))
            } else if p < lineEnd, u[p] == 0x23 {
                var h = 0
                while p + h < lineEnd, u[p + h] == 0x23 { h += 1 }
                if h <= 6, p + h == lineEnd || u[p + h] == 0x20 || u[p + h] == 0x09, p == i {
                    out.append(HighlightSpan(range: NSRange(location: i, length: lineEnd - i), kind: .heading))
                }
            } else {
                let task = TaskList.item(char: { u[$0] }, line: NSRange(location: i, length: lineEnd - i))
                if let task, let box = task.box {
                    if task.done {
                        out.append(HighlightSpan(range: NSRange(location: task.markerStart, length: lineEnd - task.markerStart), kind: .taskDone))
                        i = lineEnd + 1
                        continue
                    }
                    out.append(HighlightSpan(range: box, kind: .taskBox))
                }
                // inline code that does not cross a newline
                var k = i
                while k < lineEnd {
                    if u[k] == 0x60 {
                        var close = k + 1
                        while close < lineEnd, u[close] != 0x60 { close += 1 }
                        if close < lineEnd {
                            out.append(HighlightSpan(range: NSRange(location: k, length: close - k + 1), kind: .code))
                            k = close + 1
                            continue
                        }
                    }
                    k += 1
                }
            }
            i = lineEnd + 1
        }
        return out
    }
}

/// Fenced code: opened by a line whose first non-space run is three or more backticks or tildes, closed by
/// the next such line of the same character. The one rule shared by coloring, task counts and task clicks.
enum MarkdownFence {
    /// 0x60 (backtick) or 0x7E (tilde) when `line` (without its newline) opens or closes a fence.
    static func marker(char: (Int) -> UInt16, line: NSRange) -> UInt16? {
        let end = NSMaxRange(line)
        var p = line.location
        while p < end, char(p) == 0x20 || char(p) == 0x09 { p += 1 }
        for ch: UInt16 in [0x60, 0x7E] {
            var k = p
            while k < end, char(k) == ch { k += 1 }
            if k - p >= 3 { return ch }
        }
        return nil
    }

    /// The fence still open after `line` given the one open before it.
    static func state(after line: NSRange, open: UInt16?, char: (Int) -> UInt16) -> UInt16? {
        guard let marker = marker(char: char, line: line) else { return open }
        guard let open else { return marker }
        return marker == open ? nil : open
    }

    /// True when the line starting at `lineStart` is inside a fence. Scans from the top.
    static func isInside(_ text: NSString, lineStart: Int) -> Bool {
        let u = Array((text.substring(to: min(lineStart, text.length)) as String).utf16)
        var open: UInt16?
        var i = 0
        while i < u.count {
            var e = i
            while e < u.count, u[e] != 0x0A { e += 1 }
            open = state(after: NSRange(location: i, length: e - i), open: open) { u[$0] }
            i = e + 1
        }
        return open != nil
    }
}
