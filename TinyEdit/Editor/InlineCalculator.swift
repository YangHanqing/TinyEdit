import Foundation

/// One cursor line, decided synchronously. Nothing here touches the text storage.
///
/// The trimmed line must be one complete expression with at least one binary operator, optionally
/// ending in `=` or in an already-written result (`=` / `≈` and a number). Fullwidth digits and
/// operators are normalized first. Arithmetic is decimal (Foundation `Decimal`), not binary floating point.
///
/// Not an expression, so no ghost: a bare number, any other character, an unfinished expression,
/// a non-finite result, or division by zero.
///
/// Dates and phone numbers are excluded up front, rather than shown as subtraction:
/// - Date: after spaces are removed, a 4-digit year, then `-` or `/`, a 1–2 digit month, the same
///   separator, and a 1–2 digit day (`2024-01-02`, `2024/1/2`, and `2024 - 01 - 02 + 1`).
/// - Phone: an integer token longer than one digit that starts with `0` (`010-12345678`, `010+1`),
///   or a line that is only integers separated by `-` (an optional leading `+`, spaces ignored) in
///   one of these shapes: 3 digits then 4 (`555-1234`); 2–4 digits then 7–8 (`021-12345678`);
///   three or more groups totalling 8 digits or more (`123-456-7890`).
///   `100-20`, `1000-2000` and `1-2-3` stay subtraction.
enum InlineCalculator {
    static let maxLineLength = 200
    static let maxParenDepth = 32
    /// Non-terminating division keeps this many significant digits and is marked `≈`.
    static let significantDigits = 12

    struct Context: Equatable {
        var mode: InlineCalculationMode
        var language: EditorLanguage
    }

    enum Edit: Equatable {
        /// Insert at the end of the line (before the newline). The ghost is this string.
        case append(String)
        /// Replace this UTF-16 range of the line with `text`. The ghost is the `→` hint, not `text`.
        case replace(NSRange, String)
    }

    struct Proposal: Equatable {
        var ghost: String
        var edit: Edit
    }

    /// `nil` when the line must not offer a ghost. `line` does not include the newline.
    static func proposal(forLine line: String) -> Proposal? {
        if line.count > maxLineLength || line.contains(where: \.isNewline) { return nil }
        let units = normalize(line)
        var lo = 0
        var hi = units.count
        while lo < hi, isSpace(units[lo]) { lo += 1 }
        while hi > lo, isSpace(units[hi - 1]) { hi -= 1 }
        if lo == hi || !units[lo..<hi].allSatisfy(isAllowed) { return nil }
        let core = Array(units[lo..<hi])
        let trailingSpace = hi < units.count

        if let result = splitResult(core), let value = evaluate(Array(core[0..<result.exprEnd])) {
            guard let formatted = format(value) else { return nil }
            if sameNumber(result.number, formatted.text) { return nil }
            let marker: UInt16 = formatted.approximate ? approxChar : eqChar
            let text = markerText(marker, spaced: result.spaced, number: formatted.text)
            let range = NSRange(location: lo + result.markerIndex, length: units.count - (lo + result.markerIndex))
            return Proposal(ghost: (trailingSpace ? "" : " ") + "→ " + formatted.text, edit: .replace(range, text))
        }
        if let trail = splitTrailingEquals(core), let value = evaluate(Array(core[0..<trail.exprEnd])) {
            guard let formatted = format(value) else { return nil }
            let insert = appendAfterEquals(formatted.text, spaceBeforeEquals: trail.spaceBefore, trailingSpace: trailingSpace)
            return Proposal(ghost: insert, edit: .append(insert))
        }
        if let value = evaluate(core), let formatted = format(value) {
            let marker = formatted.approximate ? "≈" : "="
            let insert = (trailingSpace ? "" : " ") + marker + " " + formatted.text
            return Proposal(ghost: insert, edit: .append(insert))
        }
        return nil
    }

    /// Plain text always, markdown only outside fenced blocks and lines that contain a backtick.
    /// A markdown prefix longer than 256 Ki UTF-16 units is skipped (no ghost) so a keystroke never walks a huge file.
    static func isEligible(_ context: Context, text: NSString, index: Int) -> Bool {
        switch context.mode {
        case .off:
            return false
        case .plainText:
            return context.language == .plain
        case .plainTextAndMarkdown:
            if context.language == .plain { return true }
            if context.language == .markdown { return !markdownBlocks(text, index: index) }
            return false
        }
    }

    // MARK: Adopted lines

    private struct TrailingResult {
        var exprEnd: Int
        var markerIndex: Int
        var spaced: Bool
        var number: String
    }

    /// `expr = number` or `expr ≈ number`, with the number tight against the end of the trimmed line.
    private static func splitResult(_ core: [UInt16]) -> TrailingResult? {
        guard let markerIndex = core.lastIndex(where: { $0 == eqChar || $0 == approxChar }) else { return nil }
        var i = markerIndex + 1
        while i < core.count, isSpace(core[i]) { i += 1 }
        let spaced = i > markerIndex + 1
        guard i < core.count else { return nil }
        let numStart = i
        if core[i] == plusChar || core[i] == minusChar { i += 1 }
        var sawDigit = false
        var sawDot = false
        while i < core.count {
            if isDigit(core[i]) { sawDigit = true; i += 1 }
            else if core[i] == dotChar, !sawDot { sawDot = true; i += 1 }
            else { break }
        }
        guard sawDigit, i == core.count else { return nil }
        var exprEnd = markerIndex
        while exprEnd > 0, isSpace(core[exprEnd - 1]) { exprEnd -= 1 }
        guard exprEnd > 0 else { return nil }
        let number = decode(core[numStart..<i])
        return TrailingResult(exprEnd: exprEnd, markerIndex: markerIndex, spaced: spaced, number: number)
    }

    /// A trailing `=` with nothing after it. The caller's line may still have spaces after that `=`.
    private static func splitTrailingEquals(_ core: [UInt16]) -> (exprEnd: Int, spaceBefore: Bool)? {
        guard let markerIndex = core.lastIndex(of: eqChar) else { return nil }
        if markerIndex + 1 != core.count { return nil }
        var exprEnd = markerIndex
        while exprEnd > 0, isSpace(core[exprEnd - 1]) { exprEnd -= 1 }
        guard exprEnd > 0 else { return nil }
        return (exprEnd, exprEnd < markerIndex)
    }

    private static func appendAfterEquals(_ number: String, spaceBeforeEquals: Bool, trailingSpace: Bool) -> String {
        if trailingSpace || !spaceBeforeEquals { return number }
        return " " + number
    }

    private static func markerText(_ marker: UInt16, spaced: Bool, number: String) -> String {
        let sign = marker == approxChar ? "≈" : "="
        return spaced ? sign + " " + number : sign + number
    }

    /// Numeric equality, so `2`, `2.0` and `+2` all count as the same adopted result.
    private static func sameNumber(_ user: String, _ canonical: String) -> Bool {
        guard let a = signedFraction(user), let b = signedFraction(canonical) else { return false }
        guard let left = mul(a.num, b.den), let right = mul(b.num, a.den) else { return false }
        return left == right
    }

    private static func signedFraction(_ text: String) -> Fraction? {
        let units = Array(text.utf16)
        var i = 0
        var negative = false
        if i < units.count, units[i] == plusChar { i += 1 }
        else if i < units.count, units[i] == minusChar { negative = true; i += 1 }
        guard i < units.count, var value = fraction(units[i..<units.count]) else { return nil }
        if negative {
            guard let n = negDec(value.num) else { return nil }
            value.num = n
        }
        return value.reduced()
    }

    // MARK: Eligibility

    private static let markdownScanLimit = 1 << 18

    private static func markdownBlocks(_ text: NSString, index: Int) -> Bool {
        let safe = min(max(index, 0), text.length)
        let line = text.lineRange(for: NSRange(location: safe, length: 0))
        var contentEnd = NSMaxRange(line)
        if contentEnd > line.location, text.character(at: contentEnd - 1) == 0x0A { contentEnd -= 1 }
        if line.location > markdownScanLimit { return true }
        for i in line.location..<contentEnd where text.character(at: i) == 0x60 { return true }
        if fenceMarker(text, start: line.location, end: contentEnd) != 0 { return true }
        var i = 0
        var fence: unichar = 0
        while i < line.location {
            var end = i
            while end < text.length, text.character(at: end) != 0x0A { end += 1 }
            let marker = fenceMarker(text, start: i, end: end)
            if fence != 0 {
                if marker == fence { fence = 0 }
            } else if marker != 0 {
                fence = marker
            }
            if end >= text.length { break }
            i = end + 1
        }
        return fence != 0
    }

    /// Opening run of a fence, matching `MarkdownHighlighter`: 3+ `` ` `` or `~` after leading whitespace.
    private static func fenceMarker(_ text: NSString, start: Int, end: Int) -> unichar {
        var p = start
        while p < end, text.character(at: p) == 0x20 || text.character(at: p) == 0x09 { p += 1 }
        guard p < end else { return 0 }
        let ch = text.character(at: p)
        guard ch == 0x60 || ch == 0x7E else { return 0 }
        var n = 0
        while p + n < end, text.character(at: p + n) == ch { n += 1 }
        return n >= 3 ? ch : 0
    }

    // MARK: Characters

    private static let plusChar: UInt16 = 0x2B
    private static let minusChar: UInt16 = 0x2D
    private static let starChar: UInt16 = 0x2A
    private static let slashChar: UInt16 = 0x2F
    private static let dotChar: UInt16 = 0x2E
    private static let lParen: UInt16 = 0x28
    private static let rParen: UInt16 = 0x29
    private static let eqChar: UInt16 = 0x3D
    private static let approxChar: UInt16 = 0x2248

    private static func isSpace(_ u: UInt16) -> Bool { u == 0x20 || u == 0x09 }
    private static func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }

    private static func isAllowed(_ u: UInt16) -> Bool {
        isSpace(u) || isDigit(u) || u == dotChar || u == plusChar || u == minusChar || u == starChar
            || u == slashChar || u == lParen || u == rParen || u == eqChar || u == approxChar
    }

    /// Fullwidth digits and operators, `×` `÷`, and the unicode minus, mapped 1:1 so indexes still match the line.
    private static func normalize(_ line: String) -> [UInt16] {
        var out: [UInt16] = []
        out.reserveCapacity(line.utf16.count)
        for u in line.utf16 {
            switch u {
            case 0xFF10...0xFF19: out.append(u - 0xFF10 + 0x30)
            case 0xFF0B: out.append(plusChar)
            case 0xFF0D, 0x2212: out.append(minusChar)
            case 0xFF08: out.append(lParen)
            case 0xFF09: out.append(rParen)
            case 0xFF0A, 0x00D7: out.append(starChar)
            case 0xFF0F, 0x00F7: out.append(slashChar)
            case 0xFF1D: out.append(eqChar)
            case 0xFF0E: out.append(dotChar)
            case 0x3000, 0x00A0: out.append(0x20)
            default: out.append(u)
            }
        }
        return out
    }

    private static func decode(_ units: ArraySlice<UInt16>) -> String {
        String(utf16CodeUnits: Array(units), count: units.count)
    }

    // MARK: Exclusions

    private static func containsDate(_ expr: [UInt16]) -> Bool {
        let compact = expr.filter { !isSpace($0) }
        var i = 0
        while i < compact.count {
            guard isDigit(compact[i]), i == 0 || !isDigit(compact[i - 1]) else { i += 1; continue }
            var end = i
            while end < compact.count, isDigit(compact[end]) { end += 1 }
            if end - i == 4, let sep = separator(compact, end), let month = readDigits(compact, sep.index + 1),
               (1...2).contains(month.count), month.end < compact.count, compact[month.end] == sep.char,
               let day = readDigits(compact, month.end + 1), (1...2).contains(day.count),
               day.end == compact.count || !isDigit(compact[day.end]) {
                return true
            }
            i = end
        }
        return false
    }

    private static func separator(_ u: [UInt16], _ i: Int) -> (char: UInt16, index: Int)? {
        guard i < u.count, u[i] == minusChar || u[i] == slashChar else { return nil }
        return (u[i], i)
    }

    private static func readDigits(_ u: [UInt16], _ start: Int) -> (count: Int, end: Int)? {
        guard start < u.count, isDigit(u[start]) else { return nil }
        var end = start
        while end < u.count, isDigit(u[end]) { end += 1 }
        return (end - start, end)
    }

    private static func isPhone(_ expr: [UInt16]) -> Bool {
        if hasLeadingZeroInteger(expr) { return true }
        var body = expr.filter { !isSpace($0) }
        if body.first == plusChar { body.removeFirst() }
        guard let first = body.first, isDigit(first) else { return false }
        var groups: [Int] = []
        var i = 0
        while i < body.count {
            guard isDigit(body[i]) else { return false }
            let start = i
            while i < body.count, isDigit(body[i]) { i += 1 }
            groups.append(i - start)
            if i == body.count { break }
            guard body[i] == minusChar else { return false }
            i += 1
            if i == body.count { return false }
        }
        guard groups.count >= 2 else { return false }
        if groups.count == 2 {
            let left = groups[0], right = groups[1]
            if left == 3, right == 4 { return true }
            if (2...4).contains(left), (7...8).contains(right) { return true }
            return false
        }
        return groups.reduce(0, +) >= 8
    }

    private static func hasLeadingZeroInteger(_ expr: [UInt16]) -> Bool {
        var i = 0
        while i < expr.count {
            guard isDigit(expr[i]) else { i += 1; continue }
            let start = i
            while i < expr.count, isDigit(expr[i]) { i += 1 }
            let precededByDot = start > 0 && expr[start - 1] == dotChar
            let followedByDot = i < expr.count && expr[i] == dotChar
            if !precededByDot, !followedByDot, i - start > 1, expr[start] == 0x30 { return true }
        }
        return false
    }

    // MARK: Decimal arithmetic

    private struct Fraction {
        var num: Decimal
        var den: Decimal

        func reduced() -> Fraction? { InlineCalculator.reduce(self) }
    }

    private struct Formatted {
        var text: String
        var approximate: Bool
    }

    private static func evaluate(_ expr: [UInt16]) -> Fraction? {
        if expr.isEmpty || containsDate(expr) || isPhone(expr) { return nil }
        var parser = Parser(units: expr)
        guard let value = parser.parseExpression() else { return nil }
        parser.skip()
        guard parser.i == expr.count, parser.binaryOps >= 1, parser.maxDepth <= maxParenDepth else { return nil }
        return value.reduced()
    }

    private struct Parser {
        let units: [UInt16]
        var i = 0
        var binaryOps = 0
        var depth = 0
        var maxDepth = 0

        mutating func skip() {
            while i < units.count, isSpace(units[i]) { i += 1 }
        }

        mutating func parseExpression() -> Fraction? {
            guard var left = parseTerm() else { return nil }
            while true {
                skip()
                guard i < units.count, units[i] == plusChar || units[i] == minusChar else { break }
                let op = units[i]
                i += 1
                binaryOps += 1
                guard let right = parseTerm() else { return nil }
                guard let next = op == plusChar ? add(left, right) : subtract(left, right) else { return nil }
                left = next
            }
            return left
        }

        mutating func parseTerm() -> Fraction? {
            guard var left = parseUnary() else { return nil }
            while true {
                skip()
                guard i < units.count, units[i] == starChar || units[i] == slashChar else { break }
                let op = units[i]
                i += 1
                binaryOps += 1
                guard let right = parseUnary() else { return nil }
                guard let next = op == starChar ? multiply(left, right) : divide(left, right) else { return nil }
                left = next
            }
            return left
        }

        mutating func parseUnary() -> Fraction? {
            skip()
            guard i < units.count else { return nil }
            if units[i] == plusChar || units[i] == minusChar {
                let op = units[i]
                i += 1
                guard let value = parseUnary() else { return nil }
                return op == minusChar ? negate(value) : value
            }
            return parsePrimary()
        }

        mutating func parsePrimary() -> Fraction? {
            skip()
            guard i < units.count else { return nil }
            if units[i] == lParen {
                i += 1
                depth += 1
                maxDepth = max(maxDepth, depth)
                if maxDepth > maxParenDepth { return nil }
                guard let value = parseExpression() else { return nil }
                skip()
                guard i < units.count, units[i] == rParen else { return nil }
                i += 1
                depth -= 1
                return value
            }
            return parseNumber()
        }

        mutating func parseNumber() -> Fraction? {
            skip()
            let start = i
            var sawDigit = false
            var sawDot = false
            while i < units.count {
                if isDigit(units[i]) {
                    sawDigit = true
                    i += 1
                } else if units[i] == dotChar, !sawDot {
                    sawDot = true
                    i += 1
                } else {
                    break
                }
            }
            guard sawDigit else { return nil }
            return fraction(units[start..<i])
        }
    }

    private static func fraction(_ units: ArraySlice<UInt16>) -> Fraction? {
        var num = Decimal(0)
        var scale = 0
        var seenDot = false
        var digits = 0
        for u in units {
            if u == dotChar { seenDot = true; continue }
            guard let scaled = mul(num, 10), let next = addDec(scaled, Decimal(Int(u - 0x30))) else { return nil }
            num = next
            digits += 1
            if seenDot { scale += 1 }
            if digits > 38 { return nil }
        }
        var den = Decimal(1)
        for _ in 0..<scale {
            guard let next = mul(den, 10) else { return nil }
            den = next
        }
        return Fraction(num: num, den: den)
    }

    private static func add(_ a: Fraction, _ b: Fraction) -> Fraction? {
        guard let ad = mul(a.num, b.den), let bc = mul(b.num, a.den), let num = addDec(ad, bc), let den = mul(a.den, b.den) else { return nil }
        return Fraction(num: num, den: den).reduced()
    }

    private static func subtract(_ a: Fraction, _ b: Fraction) -> Fraction? {
        guard let ad = mul(a.num, b.den), let bc = mul(b.num, a.den), let num = subDec(ad, bc), let den = mul(a.den, b.den) else { return nil }
        return Fraction(num: num, den: den).reduced()
    }

    private static func multiply(_ a: Fraction, _ b: Fraction) -> Fraction? {
        guard let num = mul(a.num, b.num), let den = mul(a.den, b.den) else { return nil }
        return Fraction(num: num, den: den).reduced()
    }

    private static func divide(_ a: Fraction, _ b: Fraction) -> Fraction? {
        if b.num == 0 { return nil }
        guard let num = mul(a.num, b.den), let den = mul(a.den, b.num) else { return nil }
        return Fraction(num: num, den: den).reduced()
    }

    private static func negate(_ a: Fraction) -> Fraction? {
        guard let num = negDec(a.num) else { return nil }
        return Fraction(num: num, den: a.den).reduced()
    }

    private static func reduce(_ f: Fraction) -> Fraction? {
        if f.den == 0 || !f.num.isFinite || !f.den.isFinite { return nil }
        var n = f.num
        var d = f.den
        if d < 0 {
            guard let nn = negDec(n), let dd = negDec(d) else { return nil }
            n = nn
            d = dd
        }
        let an: Decimal
        if n < 0 {
            guard let absn = negDec(n) else { return nil }
            an = absn
        } else {
            an = n
        }
        guard let g = gcd(an, d) else { return nil }
        guard let nn = divExact(n, g), let dd = divExact(d, g) else { return nil }
        return Fraction(num: nn, den: dd)
    }

    // MARK: Display

    /// Terminating decimals are printed in full (up to 48 places). Anything else rounds to 12 significant digits.
    private static func format(_ fraction: Fraction) -> Formatted? {
        guard let reduced = fraction.reduced() else { return nil }
        let negative = reduced.num < 0
        let num: Decimal
        if negative {
            guard let absn = negDec(reduced.num) else { return nil }
            num = absn
        } else {
            num = reduced.num
        }
        guard let (ip, rem) = divmod(num, reduced.den), let intStr = integerDigits(ip) else { return nil }
        if rem == 0 {
            return Formatted(text: negative && ip != 0 ? "-" + intStr : intStr, approximate: false)
        }
        if let scale = terminatingScale(reduced.den), scale <= 48 {
            var digits: [Int] = []
            var rest = rem
            for _ in 0..<scale {
                guard let times = mul(rest, 10), let (qd, rd) = divmod(times, reduced.den), let digit = asDigit(qd) else { return nil }
                digits.append(digit)
                rest = rd
            }
            guard rest == 0 else { return nil }
            while digits.last == 0 { digits.removeLast() }
            if digits.isEmpty { return Formatted(text: negative && ip != 0 ? "-" + intStr : intStr, approximate: false) }
            let body = intStr + "." + digits.map(String.init).joined()
            return Formatted(text: (negative ? "-" : "") + body, approximate: false)
        }
        // Zeros between the decimal point and the first nonzero digit are not significant.
        // Keep dividing until 12 significant digits and one rounding digit are in hand.
        let intSig = intStr == "0" ? 0 : intStr.count
        var frac: [Int] = []
        var rest = rem
        var sig = intSig
        let target = significantDigits + 1
        while rest != 0, sig < target, frac.count < 160 {
            guard let times = mul(rest, 10), let (qd, rd) = divmod(times, reduced.den), let digit = asDigit(qd) else { return nil }
            frac.append(digit)
            rest = rd
            if sig > 0 || digit != 0 { sig += 1 }
        }
        if rest != 0, sig < target { return nil }
        guard let text = roundSignificant(intStr: intStr, frac: frac, negative: negative) else { return nil }
        return Formatted(text: text, approximate: true)
    }

    /// Decimal places of a lowest-terms denominator whose only prime factors are 2 and 5. Nil when it repeats.
    private static func terminatingScale(_ den: Decimal) -> Int? {
        var d = den
        var twos = 0
        var fives = 0
        while d != 1 {
            guard let (q2, r2) = divmod(d, 2) else { return nil }
            if r2 == 0 { twos += 1; d = q2; continue }
            guard let (q5, r5) = divmod(d, 5) else { return nil }
            if r5 == 0 { fives += 1; d = q5; continue }
            return nil
        }
        return max(twos, fives)
    }

    private static func roundSignificant(intStr: String, frac: [Int], negative: Bool) -> String? {
        var digits = intStr.compactMap(\.wholeNumberValue)
        guard digits.count == intStr.count else { return nil }
        let decimalAt = digits.count
        digits.append(contentsOf: frac)
        guard let first = digits.firstIndex(where: { $0 != 0 }) else { return "0" }
        let end = first + significantDigits
        while digits.count <= end { digits.append(0) }
        let roundDigit = digits[end]
        var kept = Array(digits[0..<end])
        var point = decimalAt
        if roundDigit >= 5 {
            var index = kept.count - 1
            var carry = true
            while carry, index >= 0 {
                if kept[index] < 9 {
                    kept[index] += 1
                    carry = false
                } else {
                    kept[index] = 0
                    index -= 1
                }
            }
            if carry {
                kept.insert(1, at: 0)
                point += 1
            }
        }
        let intDigits: [Int]
        let fracDigits: [Int]
        if point >= kept.count {
            intDigits = kept + Array(repeating: 0, count: point - kept.count)
            fracDigits = []
        } else if point <= 0 {
            intDigits = [0]
            fracDigits = Array(repeating: 0, count: -point) + kept
        } else {
            intDigits = Array(kept[0..<point])
            fracDigits = Array(kept[point...])
        }
        var ints = intDigits
        while ints.count > 1, ints[0] == 0 { ints.removeFirst() }
        var fracs = fracDigits
        while fracs.last == 0 { fracs.removeLast() }
        var text = ints.map(String.init).joined()
        if !fracs.isEmpty { text += "." + fracs.map(String.init).joined() }
        if negative, text != "0" { text = "-" + text }
        return text
    }

    private static func integerDigits(_ n: Decimal) -> String? {
        if n == 0 { return "0" }
        if n < 0 { return nil }
        var x = n
        var digits: [Int] = []
        var steps = 0
        while x != 0 {
            steps += 1
            if steps > 40 { return nil }
            guard let (q, r) = divmod(x, 10), let digit = asDigit(r) else { return nil }
            digits.append(digit)
            x = q
        }
        return digits.reversed().map(String.init).joined()
    }

    private static func asDigit(_ n: Decimal) -> Int? {
        guard n >= 0, n <= 9 else { return nil }
        let value = NSDecimalNumber(decimal: n).intValue
        return Decimal(value) == n ? value : nil
    }

    private static func mul(_ a: Decimal, _ b: Decimal) -> Decimal? {
        var r = Decimal(), x = a, y = b
        return checked(NSDecimalMultiply(&r, &x, &y, .plain), r)
    }

    private static func addDec(_ a: Decimal, _ b: Decimal) -> Decimal? {
        var r = Decimal(), x = a, y = b
        return checked(NSDecimalAdd(&r, &x, &y, .plain), r)
    }

    private static func subDec(_ a: Decimal, _ b: Decimal) -> Decimal? {
        var r = Decimal(), x = a, y = b
        return checked(NSDecimalSubtract(&r, &x, &y, .plain), r)
    }

    private static func negDec(_ a: Decimal) -> Decimal? { subDec(0, a) }

    /// Integer quotient and remainder. Both arguments are non-negative and the divisor is not zero.
    private static func divmod(_ n: Decimal, _ d: Decimal) -> (Decimal, Decimal)? {
        if d == 0 || n < 0 || d < 0 { return nil }
        var q = Decimal(), nn = n, dd = d
        let err = NSDecimalDivide(&q, &nn, &dd, .down)
        if decimalFailed(err), err != .lossOfPrecision || !q.isFinite { return nil }
        var qi = Decimal(), qq = q
        NSDecimalRound(&qi, &qq, 0, .down)
        guard let prod = mul(qi, d), let rem = subDec(n, prod) else { return nil }
        if rem < 0 {
            guard let qi2 = subDec(qi, 1), let prod2 = mul(qi2, d), let rem2 = subDec(n, prod2), rem2 >= 0, rem2 < d else { return nil }
            return (qi2, rem2)
        }
        if rem >= d {
            guard let qi2 = addDec(qi, 1), let prod2 = mul(qi2, d), let rem2 = subDec(n, prod2), rem2 >= 0, rem2 < d else { return nil }
            return (qi2, rem2)
        }
        return (qi, rem)
    }

    private static func divExact(_ n: Decimal, _ d: Decimal) -> Decimal? {
        if d == 0 { return nil }
        var q = Decimal(), nn = n, dd = d
        let err = NSDecimalDivide(&q, &nn, &dd, .plain)
        guard let prod = mul(q, d), prod == n, err == .noError || err == .lossOfPrecision, q.isFinite else { return nil }
        return q
    }

    private static func gcd(_ a: Decimal, _ b: Decimal) -> Decimal? {
        var x = a, y = b
        var steps = 0
        while y != 0 {
            steps += 1
            if steps > 80 { return nil }
            guard let (_, r) = divmod(x, y) else { return nil }
            x = y
            y = r
        }
        return x == 0 ? nil : x
    }

    /// Numerators and denominators are integers, which `Decimal` holds exactly below 10^38. Past that it
    /// rounds silently and still reports `.noError`, so a larger result is refused rather than shown as exact.
    private static let exactLimit = Decimal(sign: .plus, exponent: 38, significand: 1)

    private static func checked(_ err: NSDecimalNumber.CalculationError, _ value: Decimal) -> Decimal? {
        if decimalFailed(err) || !value.isFinite || value.magnitude >= exactLimit { return nil }
        return value
    }

    /// One error is reported at a time. Loss of precision is a failure: the ghost must not round mid-expression.
    private static func decimalFailed(_ err: NSDecimalNumber.CalculationError) -> Bool {
        err != .noError
    }
}
