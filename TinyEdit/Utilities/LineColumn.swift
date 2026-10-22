import Foundation

enum LineColumn {
    /// Without a current line index, prefix walks longer than this are skipped.
    static let maxScanLength = 200_000

    /// 1-based line and UTF-16 column for `location`. `index` must have been built from `text` as it is now;
    /// with it any line is found by binary search, without it the line is nil when the prefix is too long to scan.
    static func compute(in text: NSString, location: Int, index: LineIndex? = nil) -> (line: Int?, column: Int) {
        let loc = max(0, min(location, text.length))
        if let index, loc <= index.indexedLength {
            let line = index.line(containing: loc)
            return (line, loc - index.starts[line - 1] + 1)
        }
        var lineStart = 0
        var i = loc
        while i > 0 {
            if text.character(at: i - 1) == 0x0A { lineStart = i; break }
            i -= 1
            if loc - i > maxScanLength { return (nil, loc - i + 1) }
        }
        let column = loc - lineStart + 1
        guard loc <= maxScanLength else { return (nil, column) }
        var line = 1
        var chunk = [UInt16](repeating: 0, count: 4096)
        var pos = 0
        while pos < loc {
            let n = min(chunk.count, loc - pos)
            chunk.withUnsafeMutableBufferPointer { buf in
                text.getCharacters(buf.baseAddress!, range: NSRange(location: pos, length: n))
                for k in 0..<n where buf[k] == 0x0A { line += 1 }
            }
            pos += n
        }
        return (line, column)
    }
}
