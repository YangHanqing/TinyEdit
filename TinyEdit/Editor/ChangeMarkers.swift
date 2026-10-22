import Foundation

/// A run of lines that a disk reload added or changed, or the line a removed run sat above.
/// Session-only: never stored, cleared by the next reload or View ▸ Clear Change Markers.
struct ChangeMarker: Equatable, Sendable {
    enum Kind: Sendable { case added, modified, deleted }
    var kind: Kind
    /// UTF-16 range of whole lines in the buffer. Empty for `.deleted`: the start of the line below the removed run.
    var range: NSRange
}

struct LineChanges: Equatable, Sendable {
    var markers: [ChangeMarker]
    var added: Int
    var removed: Int

    /// "+3 −1", or nil when no line changed (an encoding or line-ending change).
    var summary: String? { added + removed == 0 ? nil : "+\(added) −\(removed)" }
}

enum LineDiff {
    /// No markers above this many UTF-16 units on either side.
    static let sizeLimit = 8 << 20

    /// Line diff of `old` to `new`, with markers in `new`'s coordinates. Common prefix and suffix lines are
    /// trimmed, then Myers runs on the middle; past `maxEdits` line edits the middle becomes one `.modified` run.
    static func changes(from old: String, to new: String, maxEdits: Int = 1000) -> LineChanges? {
        let a16 = Array(old.utf16), b16 = Array(new.utf16)
        guard a16.count <= sizeLimit, b16.count <= sizeLimit else { return nil }

        var ids: [ArraySlice<UInt16>: Int] = [:]
        func lines(_ u: [UInt16]) -> (ids: [Int], starts: [Int]) {
            var out: [Int] = [], starts: [Int] = []
            var start = 0
            for i in 0...u.count where i == u.count || u[i] == 0x0A {
                let slice = u[start..<i]
                if let id = ids[slice] {
                    out.append(id)
                } else {
                    ids[slice] = ids.count
                    out.append(ids.count - 1)
                }
                starts.append(start)
                start = i + 1
            }
            return (out, starts)
        }
        let a = lines(a16).ids
        let (b, starts) = lines(b16)

        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        let midA = Array(a[prefix..<(a.count - suffix)]), midB = Array(b[prefix..<(b.count - suffix)])
        var hunks: [Hunk] = []
        if !midA.isEmpty || !midB.isEmpty {
            hunks = myers(midA, midB, maxEdits: maxEdits)
                ?? [Hunk(newStart: 0, inserted: midB.count, removed: midA.count)]
        }

        func offset(ofLine i: Int) -> Int { i < starts.count ? starts[i] : b16.count }
        var markers: [ChangeMarker] = []
        for h in hunks {
            let first = prefix + h.newStart
            let lo = offset(ofLine: first)
            if h.inserted == 0 {
                markers.append(ChangeMarker(kind: .deleted, range: NSRange(location: lo, length: 0)))
            } else {
                let hi = offset(ofLine: first + h.inserted)
                // An added empty last line (a newline appended at EOF) has no line to mark.
                if hi > lo { markers.append(ChangeMarker(kind: h.removed == 0 ? .added : .modified, range: NSRange(location: lo, length: hi - lo))) }
            }
        }
        return LineChanges(markers: markers,
                           added: hunks.reduce(0) { $0 + $1.inserted },
                           removed: hunks.reduce(0) { $0 + $1.removed })
    }

    struct Hunk: Equatable {
        var newStart: Int
        var inserted: Int
        var removed: Int
    }

    /// Myers' O((N+M)D) shortest edit script, grouped into hunks. Nil past `maxEdits`.
    static func myers(_ a: [Int], _ b: [Int], maxEdits: Int) -> [Hunk]? {
        let n = a.count, m = b.count
        let maxD = min(n + m, maxEdits)
        let off = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)   // v[off + k]: furthest x on diagonal k
        var trace: [[Int]] = []                             // trace[d][k + d + 1]: v[k] before step d
        var found = false
        search: for d in 0...maxD {
            trace.append(Array(v[(off - d - 1)...(off + d + 1)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[off + k - 1] < v[off + k + 1])) ? v[off + k + 1] : v[off + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[off + k] = x
                if x >= n, y >= m {
                    found = true
                    break search
                }
            }
        }
        guard found else { return nil }

        var removed = [Bool](repeating: false, count: n), inserted = [Bool](repeating: false, count: m)
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let t = trace[d]
            let k = x - y
            let prevK = (k == -d || (k != d && t[k - 1 + d + 1] < t[k + 1 + d + 1])) ? k + 1 : k - 1
            let prevX = t[prevK + d + 1], prevY = prevX - prevK
            while x > prevX, y > prevY {
                x -= 1
                y -= 1
            }
            if d > 0 {
                if x == prevX { inserted[prevY] = true } else { removed[prevX] = true }
            }
            x = prevX
            y = prevY
        }

        var hunks: [Hunk] = []
        var i = 0, j = 0
        while i < n || j < m {
            guard (i < n && removed[i]) || (j < m && inserted[j]) else {
                i += 1
                j += 1
                continue
            }
            var h = Hunk(newStart: j, inserted: 0, removed: 0)
            while (i < n && removed[i]) || (j < m && inserted[j]) {
                if i < n && removed[i] {
                    i += 1
                    h.removed += 1
                } else {
                    j += 1
                    h.inserted += 1
                }
            }
            hunks.append(h)
        }
        return hunks
    }
}

extension ChangeMarker {
    /// Moves markers through one character edit, as `NSTextStorage` reports it. Text typed inside a marked run
    /// stays marked; a marker whose text is replaced entirely is dropped.
    static func adjusting(_ markers: [ChangeMarker], editedRange: NSRange, delta: Int) -> [ChangeMarker] {
        let s = editedRange.location, newLen = editedRange.length
        let oldLen = newLen - delta, oldEnd = s + oldLen
        var out: [ChangeMarker] = []
        out.reserveCapacity(markers.count)
        for m in markers {
            let ms = m.range.location, me = NSMaxRange(m.range)
            if m.kind == .deleted {
                if ms <= s {
                    out.append(m)
                } else if ms >= oldEnd {
                    out.append(ChangeMarker(kind: .deleted, range: NSRange(location: ms + delta, length: 0)))
                }
                continue
            }
            if oldLen > 0, s <= ms, me <= oldEnd { continue }
            var ns = ms <= s ? ms : (ms >= oldEnd ? ms + delta : s)
            let ne = me <= s ? me : (me >= oldEnd ? me + delta : s + newLen)
            if let last = out.last, last.kind != .deleted { ns = max(ns, NSMaxRange(last.range)) }
            if ne > ns { out.append(ChangeMarker(kind: m.kind, range: NSRange(location: ns, length: ne - ns))) }
        }
        return out
    }
}

extension Array where Element == ChangeMarker {
    struct GutterHit: Equatable {
        var bar: ChangeMarker.Kind?
        var deletedAbove = false
        var deletedBelow = false
    }

    /// What the gutter draws next to one paragraph. Markers are sorted and do not overlap.
    func gutterHit(paragraph p: NSRange, documentLength: Int) -> GutterHit {
        var hit = GutterHit()
        var lo = 0, hi = count   // first marker at or after the paragraph start
        while lo < hi {
            let mid = (lo + hi) / 2
            if self[mid].range.location < p.location { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, self[lo - 1].kind != .deleted, NSMaxRange(self[lo - 1].range) > p.location { hit.bar = self[lo - 1].kind }
        let end = p.location + Swift.max(p.length, 1)
        var i = lo
        while i < count, self[i].range.location < end {
            let m = self[i]
            if m.kind == .deleted {
                if m.range.location == p.location { hit.deletedAbove = true }
            } else if hit.bar == nil {
                hit.bar = m.kind
            }
            i += 1
        }
        if NSMaxRange(p) == documentLength, let last, last.kind == .deleted, last.range.location == documentLength,
           p.location < documentLength {
            hit.deletedBelow = true
        }
        return hit
    }
}
