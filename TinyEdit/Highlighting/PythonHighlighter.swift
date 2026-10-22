import Foundation

enum PythonHighlighter {
    static let keywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
        "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not",
        "or", "pass", "raise", "return", "try", "while", "with", "yield", "match", "case",
    ]
    private static let prefixes: Set<UInt16> = Set("rfbuRFBU".utf16)

    static func scan(_ u: [UInt16]) -> [HighlightSpan] {
        var out: [HighlightSpan] = []
        let n = u.count
        var i = 0
        func isQuote(_ c: UInt16) -> Bool { c == 0x22 || c == 0x27 }

        func string(from start: Int, quoteAt q: Int) -> Int {
            let quote = u[q]
            var j = q
            let triple = j + 2 < n && u[j + 1] == quote && u[j + 2] == quote
            if triple {
                j += 3
                while j < n {
                    if u[j] == 0x5C { j += 2; continue }
                    if u[j] == quote, j + 2 < n, u[j + 1] == quote, u[j + 2] == quote { return j + 3 }
                    j += 1
                }
                return n
            }
            j += 1
            while j < n, u[j] != 0x0A {
                if u[j] == 0x5C { j += 2; continue }
                if u[j] == quote { return j + 1 }
                j += 1
            }
            return min(j, n)
        }

        while i < n {
            let c = u[i]
            if c == 0x23 {
                let s = i
                while i < n, u[i] != 0x0A { i += 1 }
                out.append(HighlightSpan(range: NSRange(location: s, length: i - s), kind: .comment))
            } else if isQuote(c) {
                let e = string(from: i, quoteAt: i)
                out.append(HighlightSpan(range: NSRange(location: i, length: e - i), kind: .string))
                i = e
            } else if SyntaxHighlighter.isIdentStart(c) {
                let s = i
                while i < n, SyntaxHighlighter.isIdentPart(u[i]) { i += 1 }
                if i - s == 1, prefixes.contains(u[s]), i < n, isQuote(u[i]) {
                    let e = string(from: s, quoteAt: i)
                    out.append(HighlightSpan(range: NSRange(location: s, length: e - s), kind: .string))
                    i = e
                    continue
                }
                let word = String(decoding: u[s..<i], as: UTF16.self)
                let kind: TokenKind?
                switch word {
                case "True", "False": kind = .boolean
                case "None": kind = .null
                default: kind = keywords.contains(word) ? .keyword : nil
                }
                if let kind { out.append(HighlightSpan(range: NSRange(location: s, length: i - s), kind: kind)) }
            } else if SyntaxHighlighter.isDigit(c) {
                let s = i
                while i < n, SyntaxHighlighter.isDigit(u[i]) || u[i] == 0x2E || u[i] == 0x5F { i += 1 }
                if i < n, u[i] == 0x65 || u[i] == 0x45 {
                    i += 1
                    if i < n, u[i] == 0x2B || u[i] == 0x2D { i += 1 }
                    while i < n, SyntaxHighlighter.isDigit(u[i]) { i += 1 }
                }
                out.append(HighlightSpan(range: NSRange(location: s, length: i - s), kind: .number))
            } else {
                i += 1
            }
        }
        return out
    }
}
