import Foundation

enum LineEnding: String, Codable, Sendable {
    case lf, crlf

    var statusLabel: String { self == .lf ? "LF" : "CRLF" }

    /// Counts breaks on the decoded string. CRLF wins only when CRLF pairs outnumber
    /// bare LF plus bare CR; ties and pure CR stay LF.
    static func detect(_ text: String) -> LineEnding {
        var crlf = 0, other = 0
        var previousCR = false
        for byte in text.utf8 {
            switch byte {
            case 0x0D:
                if previousCR { other += 1 }
                previousCR = true
            case 0x0A:
                if previousCR { crlf += 1 } else { other += 1 }
                previousCR = false
            default:
                if previousCR { other += 1 }
                previousCR = false
            }
        }
        if previousCR { other += 1 }
        return crlf > other ? .crlf : .lf
    }

    /// CRLF and bare CR both fold to LF. Bare CR is not a preserved ending.
    static func normalizeToLF(_ text: String) -> String {
        guard text.utf8.contains(0x0D) else { return text }
        var out = [UInt8]()
        out.reserveCapacity(text.utf8.count)
        var previousCR = false
        for byte in text.utf8 {
            if byte == 0x0D {
                out.append(0x0A)
                previousCR = true
            } else {
                if !(byte == 0x0A && previousCR) { out.append(byte) }
                previousCR = false
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `logicalLF` should already be LF-only. A stray CR (text that entered a buffer before input
    /// folding, e.g. from an older snapshot) is folded first, so CRLF never becomes CR CR LF.
    static func apply(_ logicalLF: String, ending: LineEnding) -> String {
        let lf = normalizeToLF(logicalLF)
        switch ending {
        case .lf: return lf
        case .crlf: return lf.replacingOccurrences(of: "\n", with: "\r\n")
        }
    }
}
