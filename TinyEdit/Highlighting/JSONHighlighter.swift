import Foundation

enum JSONHighlighter {
    static func scan(_ u: [UInt16]) -> [HighlightSpan] {
        var out: [HighlightSpan] = []
        var i = 0
        let n = u.count
        while i < n {
            let c = u[i]
            if c == 0x22 {
                let start = i
                i += 1
                while i < n, u[i] != 0x22, u[i] != 0x0A {
                    if u[i] == 0x5C, i + 1 < n { i += 1 }
                    i += 1
                }
                if i < n, u[i] == 0x22 { i += 1 }
                out.append(HighlightSpan(range: NSRange(location: start, length: i - start), kind: .string))
            } else if c == 0x2D || SyntaxHighlighter.isDigit(c) {
                let start = i
                i += 1
                while i < n, SyntaxHighlighter.isDigit(u[i]) || u[i] == 0x2E || u[i] == 0x65 || u[i] == 0x45
                        || u[i] == 0x2B || u[i] == 0x2D { i += 1 }
                if i - start > 1 || SyntaxHighlighter.isDigit(c) {
                    out.append(HighlightSpan(range: NSRange(location: start, length: i - start), kind: .number))
                }
            } else if SyntaxHighlighter.isIdentStart(c) {
                let start = i
                while i < n, SyntaxHighlighter.isIdentPart(u[i]) { i += 1 }
                let word = String(decoding: u[start..<i], as: UTF16.self)
                let kind: TokenKind? = word == "true" || word == "false" ? .boolean : (word == "null" ? .null : nil)
                if let kind { out.append(HighlightSpan(range: NSRange(location: start, length: i - start), kind: kind)) }
            } else {
                i += 1
            }
        }
        return out
    }
}
