import Foundation

/// Which part of the text needs its colors redone after a new highlight pass. Pure.
///
/// TextKit 2 moves rendering attributes with the text: an edit shifts the colors after it, and the
/// characters it inserts have none. So outside the edited range the layout manager still holds the
/// previous spans, shifted by the length change, and only the range where those differ from the new
/// spans (plus the edits themselves) has to be cleared and painted again. Removing attributes costs
/// about 75 µs per colored run, which made repainting a 2 MB JSON file take seconds per pause in typing.
enum HighlightDiff {
    /// The range to clear and repaint, in current offsets, or nil when the colors on screen are already right.
    /// `edits` covers every character edit since `old` was applied, in current offsets.
    static func region(old: [HighlightSpan], oldLength: Int, new: [HighlightSpan], newLength: Int,
                       edits: NSRange?) -> NSRange? {
        let delta = newLength - oldLength
        if edits == nil, delta != 0 { return NSRange(location: 0, length: newLength) }
        let editStart = edits?.location ?? Int.max
        let editEnd = edits.map(NSMaxRange) ?? Int.min

        // Before the edits offsets are unchanged; after them they moved by `delta`.
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix],
              NSMaxRange(new[prefix].range) <= editStart {
            prefix += 1
        }
        var oldEnd = old.count, newEnd = new.count
        while oldEnd > prefix, newEnd > prefix {
            let o = old[oldEnd - 1], n = new[newEnd - 1]
            guard o.kind == n.kind, o.range.length == n.range.length, o.range.location + delta == n.range.location,
                  n.range.location >= editEnd else { break }
            oldEnd -= 1
            newEnd -= 1
        }

        // Spans come in document order but may nest, so the last one need not end last.
        var lo = editStart, hi = editEnd
        for span in old[prefix..<oldEnd] {
            lo = min(lo, span.range.location)
            hi = max(hi, NSMaxRange(span.range) + delta)
        }
        for span in new[prefix..<newEnd] {
            lo = min(lo, span.range.location)
            hi = max(hi, NSMaxRange(span.range))
        }
        lo = max(lo, 0)
        hi = min(hi, newLength)
        guard lo < hi else { return nil }
        return NSRange(location: lo, length: hi - lo)
    }

    /// `covered` (offsets before an edit) extended by that edit, in offsets after it.
    static func covering(_ covered: NSRange?, edited: NSRange, delta: Int) -> NSRange {
        guard let covered else { return edited }
        let oldEditEnd = NSMaxRange(edited) - delta
        func moved(_ x: Int) -> Int {
            if x <= edited.location { return x }
            return x >= oldEditEnd ? x + delta : NSMaxRange(edited)
        }
        let lo = min(moved(covered.location), edited.location)
        let hi = max(moved(NSMaxRange(covered)), NSMaxRange(edited))
        return NSRange(location: lo, length: hi - lo)
    }
}
