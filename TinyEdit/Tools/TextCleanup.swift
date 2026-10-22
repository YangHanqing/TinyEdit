import Foundation

/// Terminal escape sequences and invisible characters, which arrive with text copied out of a
/// terminal, a log, a web page or a chat answer. Invisible means rendering as nothing (or as a blank)
/// while rarely being intended in plain text. Characters that carry meaning in some script stay:
/// ZWJ / ZWNJ (emoji sequences, Indic, Persian), LRM / RLM, variation selectors, and the tag
/// characters of a flag emoji such as England's.
enum TextCleanup {
    struct Report: Equatable, Sendable {
        var ansiSequences = 0
        /// Per code point, ascending. Tag characters are counted together under U+E0000.
        var invisible: [InvisibleKind] = []

        var invisibleCount: Int { invisible.reduce(0) { $0 + $1.count } }
        var isEmpty: Bool { ansiSequences == 0 && invisible.isEmpty }
    }

    struct InvisibleKind: Equatable, Sendable {
        var value: UInt32
        var count: Int

        /// "U+200B ZERO WIDTH SPACE". Unicode names are not translated.
        var label: String {
            if value == TextCleanup.tagGroup { return "U+E0000–E007F TAG" }
            let code = "U+" + String(format: "%04X", value)
            guard let scalar = Unicode.Scalar(value),
                  let name = scalar.properties.name ?? scalar.properties.nameAlias else { return code }
            return "\(code) \(name)"
        }
    }

    static let tagGroup: UInt32 = 0xE0000

    static func scan(_ s: String) -> Report {
        var ansi = 0
        var counts: [UInt32: Int] = [:]
        walk(Array(s.unicodeScalars),
             onANSI: { _ in ansi += 1 },
             onInvisible: { counts[$0.value >= tagGroup ? tagGroup : $0.value, default: 0] += 1 },
             onKept: { _ in })
        let kinds = counts.keys.sorted().map { InvisibleKind(value: $0, count: counts[$0]!) }
        return Report(ansiSequences: ansi, invisible: kinds)
    }

    static func removingANSI(_ s: String) -> String { rebuild(s, ansi: true, invisible: false) }
    static func removingInvisible(_ s: String) -> String { rebuild(s, ansi: false, invisible: true) }
    static func removingAll(_ s: String) -> String { rebuild(s, ansi: true, invisible: true) }

    private static func rebuild(_ s: String, ansi: Bool, invisible: Bool) -> String {
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count)
        walk(scalars,
             onANSI: { if !ansi { out.append(contentsOf: $0) } },
             onInvisible: { if !invisible { out.append($0) } },
             onKept: { out.append($0) })
        return String(out)
    }

    /// One pass that classifies every scalar: part of an escape sequence, invisible, or kept.
    /// A stray ESC (one that starts no complete sequence) is an invisible control character.
    private static func walk(_ u: [Unicode.Scalar], onANSI: (ArraySlice<Unicode.Scalar>) -> Void,
                             onInvisible: (Unicode.Scalar) -> Void, onKept: (Unicode.Scalar) -> Void) {
        var i = 0
        var inFlagTags = false
        while i < u.count {
            let c = u[i]
            if c.value == 0x1B || c.value == 0x9B, let end = sequenceEnd(u, at: i) {
                onANSI(u[i..<end])
                i = end
                inFlagTags = false
                continue
            }
            // The tags after U+1F3F4 WAVING BLACK FLAG, up to CANCEL TAG, spell a subdivision flag.
            if (0xE0000...0xE007F).contains(c.value) {
                if inFlagTags {
                    onKept(c)
                    if c.value == 0xE007F { inFlagTags = false }
                } else {
                    onInvisible(c)
                }
                i += 1
                continue
            }
            inFlagTags = c.value == 0x1F3F4
            if isInvisible(c) { onInvisible(c) } else { onKept(c) }
            i += 1
        }
    }

    /// The index after the escape sequence starting at `i`, or nil when it is incomplete.
    /// CSI `ESC [ params intermediates final` (or C1 CSI), OSC / DCS / SOS / PM / APC strings ended
    /// by BEL or `ESC \` on the same line, `ESC intermediates final` (`ESC ( B`), and `ESC final` (`ESC 7`).
    private static func sequenceEnd(_ u: [Unicode.Scalar], at i: Int) -> Int? {
        var j: Int
        if u[i].value == 0x9B {
            j = i + 1
        } else {
            guard i + 1 < u.count else { return nil }
            let next = u[i + 1].value
            switch next {
            case 0x5B:   // [
                j = i + 2
            case 0x5D, 0x50, 0x58, 0x5E, 0x5F:   // ] P X ^ _
                var k = i + 2
                while k < u.count {
                    let v = u[k].value
                    if v == 0x07 { return k + 1 }
                    if v == 0x1B { return k + 1 < u.count && u[k + 1].value == 0x5C ? k + 2 : nil }
                    if v == 0x0A { return nil }
                    k += 1
                }
                return nil
            case 0x20...0x2F:
                var k = i + 2
                while k < u.count, (0x20...0x2F).contains(u[k].value) { k += 1 }
                return k < u.count && (0x30...0x7E).contains(u[k].value) ? k + 1 : nil
            case 0x30...0x7E:
                return i + 2
            default:
                return nil
            }
        }
        while j < u.count, (0x30...0x3F).contains(u[j].value) { j += 1 }
        while j < u.count, (0x20...0x2F).contains(u[j].value) { j += 1 }
        return j < u.count && (0x40...0x7E).contains(u[j].value) ? j + 1 : nil
    }

    /// Controls other than tab, line feed, carriage return and form feed (which source files use as
    /// a page break), and the format characters that draw nothing.
    private static func isInvisible(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x09, 0x0A, 0x0C, 0x0D: return false
        case 0x00...0x1F, 0x7F...0x9F: return true
        case 0x00AD,            // SOFT HYPHEN
             0x180E,            // MONGOLIAN VOWEL SEPARATOR
             0x200B,            // ZERO WIDTH SPACE
             0x202A...0x202E,   // bidi embeddings and overrides
             0x2060...0x2064,   // WORD JOINER, invisible operators
             0x2066...0x2069,   // bidi isolates
             0x3164, 0xFFA0,    // HANGUL FILLER, HALFWIDTH HANGUL FILLER
             0xFEFF,            // ZERO WIDTH NO-BREAK SPACE (a BOM inside the text)
             0xFFF9...0xFFFB:   // interlinear annotation
            return true
        default: return false
        }
    }
}
