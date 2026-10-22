import Foundation

/// A key-value pair or array element of a JSON document: what the status bar's Copy Key / Copy Value
/// act on.
struct JSONMember: Equatable, Sendable {
    enum Step: Equatable, Sendable {
        case key(String)
        case index(Int)
    }

    enum Kind: Equatable, Sendable {
        case string, object, array, scalar
    }

    /// From the outermost value down; the last step is this member's own key or index.
    var path: [Step]
    /// The key with its quotes. Nil for an array element.
    var keyRange: NSRange?
    var valueRange: NSRange
    var kind: Kind

    var key: String? {
        if case .key(let k) = path.last { return k }
        return nil
    }

    /// From the key (or the element's first character) to the end of the value.
    var span: NSRange {
        let start = keyRange?.location ?? valueRange.location
        return NSRange(location: start, length: NSMaxRange(valueRange) - start)
    }

    /// `data.items[0].name`; a key that is not a plain identifier is written `["a b"]`.
    var pathText: String {
        var out = ""
        for step in path {
            switch step {
            case .index(let i):
                out += "[\(i)]"
            case .key(let k) where Self.isIdentifier(k):
                out += out.isEmpty ? k : ".\(k)"
            case .key(let k):
                out += "[\(Self.quoted(k))]"
            }
        }
        return out
    }

    /// The last key and any indices after it (`items[0]`), for a tab title.
    var shortName: String {
        let lastKey = path.lastIndex { if case .key = $0 { return true } else { return false } }
        let tail = JSONMember(path: Array(path[(lastKey ?? 0)...]), keyRange: nil, valueRange: valueRange, kind: kind)
        return tail.pathText
    }

    private static func isIdentifier(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, first == "_" || first == "$" || first.properties.isAlphabetic
        else { return false }
        return s.unicodeScalars.allSatisfy { $0 == "_" || $0 == "$" || $0.properties.isAlphabetic
            || ("0"..."9").contains($0) }
    }

    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// A member value the editor marks after its line: a picture Preview would show, a link to open, a color
/// to see or a Unix time to read.
struct JSONValueMark: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case image(JSONValueInsight.ImageSource)
        case link(URL)
        case color(JSONColor)
        case date(Date, milliseconds: Bool)
        /// A JWT, Base64, `%XX` or `\uXXXX` string that Decode reads, with a JWT's `exp` when it has one.
        case decode(jwtExpiry: Date?)
    }

    var valueRange: NSRange
    var kind: Kind

    var isImage: Bool {
        if case .image = kind { return true }
        return false
    }
}

/// The innermost object or array around the caret, for the status bar.
struct JSONContainerSize: Equatable, Sendable {
    var count: Int
    var isObject: Bool

    var label: String {
        isObject ? String(localized: "\(count) keys") : String(localized: "\(count) items")
    }
}

/// Finds the JSON member around the caret. A tolerant single pass: it never requires the document to
/// parse, so a half-typed file, comments, unquoted keys and several top-level values (JSON Lines)
/// still give a result. Top-level values are not members (copying one is Select All).
enum JSONLocator {
    /// Larger documents are scanned off the main thread.
    static let synchronousLimit = 256 * 1024
    /// Beyond this the status bar offers nothing, as highlighting turns off.
    static let sizeLimit = HighlightPolicy.fullLimit

    /// The innermost member whose span (key through value, both ends included) holds all of `range`.
    static func member(around range: NSRange, in u: [UInt16]) -> JSONMember? {
        guard range.location >= 0, NSMaxRange(range) <= u.count else { return nil }
        var scanner = Scanner(u: u, target: range)
        return scanner.run()
    }

    /// Every value the editor marks, in document order, up to `limit`. The same tolerant pass as
    /// `member(around:)`, so each mark is the member a caret inside it finds.
    static func valueMarks(in u: [UInt16], limit: Int = 2_000) -> [JSONValueMark] {
        var scanner = Scanner(u: u, target: nil, markLimit: limit)
        _ = scanner.run()
        // Preserve document order for the editor decorations.
        return scanner.marks.sorted { $0.valueRange.location < $1.valueRange.location }
    }

    /// Count the nearest enclosing container, including single-line and unfinished JSON. The count
    /// is independent of the editor mark limit. Collect marks in the same pass after a document edit.
    static func context(around range: NSRange, in u: [UInt16], collectMarks: Bool = false)
        -> (marks: [JSONValueMark], size: JSONContainerSize?) {
        guard range.location >= 0, NSMaxRange(range) <= u.count else { return ([], nil) }
        var scanner = Scanner(u: u, target: nil, markLimit: collectMarks ? 2_000 : 0)
        scanner.sizeTarget = range
        _ = scanner.run()
        return (scanner.marks.sorted { $0.valueRange.location < $1.valueRange.location }, scanner.containerSize)
    }

    /// The value as it is useful on its own: a string decoded, an object or array as written but
    /// moved left by the indentation of the line it starts on, anything else as written.
    static func valueText(_ m: JSONMember, in u: [UInt16]) -> String {
        let r = m.valueRange
        switch m.kind {
        case .string:
            return decodeString(u, r) ?? String(decoding: u[r.location..<NSMaxRange(r)], as: UTF16.self)
        case .scalar:
            return String(decoding: u[r.location..<NSMaxRange(r)], as: UTF16.self)
        case .object, .array:
            return outdented(u, r, by: lineIndent(u, before: m.span.location))
        }
    }

    /// Copies a whole NSString into UTF-16 units. Call on the thread that owns the string.
    static func units(of ns: NSString) -> [UInt16] {
        let n = ns.length
        guard n > 0 else { return [] }
        return [UInt16](unsafeUninitializedCapacity: n) { buffer, count in
            ns.getCharacters(buffer.baseAddress!, range: NSRange(location: 0, length: n))
            count = n
        }
    }

    // MARK: Values

    /// The contents of a quoted string with JSON escapes resolved; nil if an escape is malformed.
    /// An unterminated string decodes to its end.
    static func decodeString(_ u: [UInt16], _ r: NSRange) -> String? {
        var i = r.location + 1
        var end = NSMaxRange(r)
        if end - 1 >= i, u[end - 1] == 0x22 { end -= 1 }
        var out: [UInt16] = []
        out.reserveCapacity(end - i)
        while i < end {
            let c = u[i]
            guard c == 0x5C else { out.append(c); i += 1; continue }
            guard i + 1 < end else { return nil }
            switch u[i + 1] {
            case 0x22: out.append(0x22)
            case 0x5C: out.append(0x5C)
            case 0x2F: out.append(0x2F)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x6E: out.append(0x0A)
            case 0x72: out.append(0x0D)
            case 0x74: out.append(0x09)
            case 0x75:
                guard i + 6 <= end, let v = hex(u, i + 2) else { return nil }
                out.append(v)
                i += 6
                continue
            default: return nil
            }
            i += 2
        }
        return String(decoding: out, as: UTF16.self)
    }

    private static func hex(_ u: [UInt16], _ at: Int) -> UInt16? {
        var v: UInt16 = 0
        for k in at..<(at + 4) {
            let c = u[k]
            let d: UInt16
            switch c {
            case 0x30...0x39: d = c - 0x30
            case 0x41...0x46: d = c - 0x41 + 10
            case 0x61...0x66: d = c - 0x61 + 10
            default: return nil
            }
            v = v << 4 | d
        }
        return v
    }

    private static func lineIndent(_ u: [UInt16], before offset: Int) -> [UInt16] {
        var start = offset
        while start > 0, u[start - 1] != 0x0A { start -= 1 }
        var end = start
        while end < offset, u[end] == 0x20 || u[end] == 0x09 { end += 1 }
        return Array(u[start..<end])
    }

    /// Removes up to `indent` from the start of every line after the first.
    private static func outdented(_ u: [UInt16], _ r: NSRange, by indent: [UInt16]) -> String {
        guard !indent.isEmpty else { return String(decoding: u[r.location..<NSMaxRange(r)], as: UTF16.self) }
        var out: [UInt16] = []
        out.reserveCapacity(r.length)
        var i = r.location
        let end = NSMaxRange(r)
        while i < end {
            let c = u[i]
            out.append(c)
            i += 1
            if c == 0x0A {
                var k = 0
                while k < indent.count, i < end, u[i] == indent[k] { i += 1; k += 1 }
            }
        }
        return String(decoding: out, as: UTF16.self)
    }

    // MARK: Scanner

    private struct Frame {
        var isObject: Bool
        var start: Int
        /// The current member's key, or nil before one is read.
        var key: (range: NSRange, quoted: Bool)?
        var afterColon = false
        var index = 0
        /// Members or elements completed so far; counted only when collecting marks.
        var count = 0
    }

    private struct Scanner {
        let u: [UInt16]
        /// Nil collects `marks` over the whole text instead of finding one member.
        let target: NSRange?
        var frames: [Frame] = []
        let markLimit: Int
        var marks: [JSONValueMark] = []
        var sizeTarget: NSRange?
        var containerSize: JSONContainerSize?

        init(u: [UInt16], target: NSRange?, markLimit: Int = 0) {
            self.u = u
            self.target = target
            self.markLimit = markLimit
        }

        mutating func run() -> JSONMember? {
            let n = u.count
            var i = 0
            while i < n {
                let c = u[i]
                switch c {
                case 0x20, 0x09, 0x0A, 0x0D:
                    i += 1
                case 0x7B, 0x5B:   // { [
                    frames.append(Frame(isObject: c == 0x7B, start: i))
                    i += 1
                case 0x7D, 0x5D:   // } ]
                    i += 1
                    guard let f = frames.popLast() else { continue }
                    let r = NSRange(location: f.start, length: i - f.start)
                    recordSize(f, r)
                    if let m = complete(r, f.isObject ? .object : .array) { return m }
                case 0x3A:   // :
                    if frames.last?.isObject == true { frames[frames.count - 1].afterColon = true }
                    i += 1
                case 0x2C:   // ,
                    if let last = frames.indices.last {
                        if frames[last].isObject {
                            frames[last].key = nil
                            frames[last].afterColon = false
                        } else {
                            frames[last].index += 1
                        }
                    }
                    i += 1
                case 0x22:
                    let start = i
                    i += 1
                    while i < n, u[i] != 0x22, u[i] != 0x0A {
                        if u[i] == 0x5C, i + 1 < n { i += 1 }
                        i += 1
                    }
                    if i < n, u[i] == 0x22 { i += 1 }
                    let r = NSRange(location: start, length: i - start)
                    if expectsKey { frames[frames.count - 1].key = (r, true) }
                    else if let m = complete(r, .string) { return m }
                case 0x2F where i + 1 < n && (u[i + 1] == 0x2F || u[i + 1] == 0x2A):
                    i = skipComment(from: i)
                default:
                    let start = i
                    while i < n, !Self.endsScalar(u[i]) { i += 1 }
                    if i == start { i += 1 }   // a lone `/`
                    let r = NSRange(location: start, length: i - start)
                    if expectsKey { frames[frames.count - 1].key = (r, false) }
                    else if let m = complete(r, .scalar) { return m }
                }
            }
            // Unclosed containers end at the end of the text.
            while let f = frames.popLast() {
                recordSize(f, NSRange(location: f.start, length: n - f.start))
                if let m = complete(NSRange(location: f.start, length: n - f.start), f.isObject ? .object : .array) {
                    return m
                }
            }
            return nil
        }

        /// Containers complete innermost first. Include their key so a caret on an object/array
        /// property's name shows that property's count, while scalar values show their parent's count.
        private mutating func recordSize(_ f: Frame, _ r: NSRange) {
            guard containerSize == nil, let sizeTarget else { return }
            let start = frames.last?.isObject == true ? (frames.last?.key?.range.location ?? r.location) : r.location
            guard start <= sizeTarget.location, NSMaxRange(sizeTarget) <= NSMaxRange(r) else { return }
            containerSize = JSONContainerSize(count: f.count, isObject: f.isObject)
        }

        private var expectsKey: Bool {
            guard let f = frames.last else { return false }
            return f.isObject && !f.afterColon
        }

        private func skipComment(from i: Int) -> Int {
            let n = u.count
            var j = i + 2
            if u[i + 1] == 0x2F {
                while j < n, u[j] != 0x0A { j += 1 }
                return j
            }
            while j + 1 < n, !(u[j] == 0x2A && u[j + 1] == 0x2F) { j += 1 }
            return min(j + 2, n)
        }

        private static func endsScalar(_ c: UInt16) -> Bool {
            switch c {
            case 0x20, 0x09, 0x0A, 0x0D, 0x7B, 0x7D, 0x5B, 0x5D, 0x2C, 0x3A, 0x22: return true
            default: return false
            }
        }

        /// A value ended in the innermost open container. Returns it if it is the member wanted;
        /// members end innermost first, so the first match is the innermost.
        private mutating func complete(_ value: NSRange, _ kind: JSONMember.Kind) -> JSONMember? {
            guard let last = frames.indices.last else { return nil }
            let frame = frames[last]
            if frame.isObject {
                frames[last].key = nil
                frames[last].afterColon = false
            }
            let keyRange = frame.isObject ? frame.key?.range : nil
            guard !frame.isObject || keyRange != nil else { return nil }
            guard let target else {
                frames[last].count += 1
                if marks.count < markLimit, let mark = markKind(value, kind, in: frame) {
                    marks.append(JSONValueMark(valueRange: value, kind: mark))
                }
                return nil
            }
            let start = keyRange?.location ?? value.location
            guard start <= target.location, NSMaxRange(target) <= NSMaxRange(value),
                  let own = step(in: frame) else { return nil }
            var path: [JSONMember.Step] = []
            for f in frames.dropLast() {
                guard let s = step(in: f) else { return nil }
                path.append(s)
            }
            path.append(own)
            return JSONMember(path: path, keyRange: keyRange, valueRange: value, kind: kind)
        }

        /// `JSONValueInsight.markKind` for this value. Numbers are read only at timestamp lengths. Strings are
        /// decoded when they start like a link, a `data:` URI, a color or a timestamp, or might have a Decode
        /// reading (16+ units with no space, or a `%` or `\`); only the latter are given the decode checks.
        private func markKind(_ value: NSRange, _ kind: JSONMember.Kind, in frame: Frame) -> JSONValueMark.Kind? {
            switch kind {
            case .object, .array:
                return nil
            case .scalar:
                guard value.length == 10 || value.length == 13 else { return nil }
                return JSONValueInsight.markKind(String(decoding: u[value.location..<NSMaxRange(value)], as: UTF16.self),
                                                 isString: false, key: nil)
            case .string:
                let i = value.location + 1
                guard value.length >= 5 else { return nil }
                let mayDecode = mightDecode(value)
                switch u[i] | 0x20 {
                case 0x68, 0x64, 0x72, 0x23, 0x30...0x39: break   // h d r # digits
                default: if !mayDecode { return nil }
                }
                if value.length > JSONValueInsight.detailLimit + 2 {
                    let head = String(decoding: u[i..<(i + 16)], as: UTF16.self)
                    return JSONValueInsight.isDataImage(head) ? .image(.inline) : nil
                }
                let text = JSONLocator.decodeString(u, value)
                    ?? String(decoding: u[value.location..<NSMaxRange(value)], as: UTF16.self)
                var key: String?
                if case .key(let k) = step(in: frame) { key = k }
                return JSONValueInsight.markKind(text, isString: true, key: key, decodes: mayDecode)
            }
        }

        /// Could a Decode reading (JWT, Base64, `%XX`, `\uXXXX`) apply to this quoted string?
        private func mightDecode(_ value: NSRange) -> Bool {
            var space = false
            for k in (value.location + 1)..<NSMaxRange(value) {
                switch u[k] {
                case 0x25, 0x5C: return true   // % \
                case 0x20: space = true
                default: break
                }
            }
            return !space && value.length >= JSONValueInsight.minimumBase64Length + 2
        }

        /// How the frame's current member is reached from it.
        private func step(in f: Frame) -> JSONMember.Step? {
            guard f.isObject else { return .index(f.index) }
            guard let key = f.key else { return nil }
            if key.quoted {
                return JSONLocator.decodeString(u, key.range).map { .key($0) }
            }
            return .key(String(decoding: u[key.range.location..<NSMaxRange(key.range)], as: UTF16.self))
        }
    }
}
