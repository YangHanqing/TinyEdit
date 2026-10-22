import Foundation

/// UTF-16 line-start index, published atomically with the generation it was built from.
struct LineIndex: Sendable {
    var generation: UInt64
    var indexedLength: Int
    var starts: [Int]

    static func build(_ text: String, generation: UInt64) -> LineIndex {
        var starts = [0]
        var i = 0
        for u in text.utf16 {
            i += 1
            if u == 0x0A { starts.append(i) }
        }
        return LineIndex(generation: generation, indexedLength: i, starts: starts)
    }

    var lineCount: Int { starts.count }

    /// 1-based line for a UTF-16 offset, via binary search.
    func line(containing offset: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    func isLineStart(_ offset: Int) -> Bool {
        let l = line(containing: offset)
        return starts[l - 1] == offset
    }
}
