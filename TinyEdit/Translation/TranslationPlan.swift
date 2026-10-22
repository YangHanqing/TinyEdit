import Foundation

struct TranslationSegment: Equatable, Sendable {
    let text: String
    let needsTranslation: Bool
}

/// Paragraphs first, then sentence/word boundaries; never split a grapheme or fenced code.
enum TranslationPlan {
    static let inputLimit = 500_000
    static let chunkLimit = 2_000
    /// A model part is bounded by its output length and the unstreamed request timeout, not its context window.
    static let modelChunkLimit = 6_000

    /// Apple translates each paragraph on its own; a model gets whole paragraphs packed up to its larger limit,
    /// which means far fewer requests and shared context for terminology.
    static func make(_ text: String, for engine: TranslationEngine) -> [TranslationSegment] {
        engine == .custom ? make(text, limit: modelChunkLimit, joinParagraphs: true) : make(text)
    }

    static func make(_ text: String, limit: Int = chunkLimit, joinParagraphs: Bool = false) -> [TranslationSegment] {
        precondition(limit > 0)
        var segments: [TranslationSegment] = []
        /// Whole paragraphs and the blank lines between them, sent as one part.
        var block = ""
        var paragraph = ""
        var code = ""
        var fence: (character: Character, count: Int)?
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        func flushBlock() {
            segments += split(block, limit: limit)
            block = ""
        }
        func endParagraph() {
            if !block.isEmpty && block.utf16.count + paragraph.utf16.count > limit { flushBlock() }
            block += paragraph
            paragraph = ""
        }
        func flushParagraph() {
            endParagraph()
            flushBlock()
        }
        for (index, line) in lines.enumerated() {
            let fullLine = String(line) + (index < lines.count - 1 ? "\n" : "")
            let content = line.drop(while: { $0 == " " || $0 == "\t" })
            if let opened = fence {
                code += fullLine
                let count = content.prefix(while: { $0 == opened.character }).count
                if count >= opened.count && content.dropFirst(count).allSatisfy(\.isWhitespace) {
                    segments.append(TranslationSegment(text: code, needsTranslation: false))
                    code = ""; fence = nil
                }
            } else if let first = content.first, first == "`" || first == "~",
                      content.prefix(while: { $0 == first }).count >= 3 {
                flushParagraph()
                fence = (first, content.prefix(while: { $0 == first }).count)
                code = fullLine
            } else if content.allSatisfy(\.isWhitespace) {
                if joinParagraphs && !(block.isEmpty && paragraph.isEmpty) {
                    endParagraph()
                    // Trailing blank lines of a part come back out of `split` as literal text.
                    block += fullLine
                } else {
                    flushParagraph()
                    if !fullLine.isEmpty { segments.append(TranslationSegment(text: fullLine, needsTranslation: false)) }
                }
            } else {
                paragraph += fullLine
            }
        }
        flushParagraph()
        if !code.isEmpty { segments.append(TranslationSegment(text: code, needsTranslation: false)) }
        return segments
    }

    static func split(_ text: String, limit: Int) -> [TranslationSegment] {
        guard !text.isEmpty else { return [] }
        var result: [TranslationSegment] = []
        var start = text.startIndex
        while start < text.endIndex {
            var end = start
            var preferred: String.Index?
            var paragraphBreak: String.Index?
            var previous: Character?
            var length = 0
            while end < text.endIndex {
                let next = text.index(after: end)
                let size = text[end..<next].utf16.count
                if length + size > limit && end > start { break }
                length += size
                let character = text[end]
                end = next
                if character.isWhitespace || ".!?。！？;；".contains(character) { preferred = end }
                if character == "\n" && previous == "\n" { paragraphBreak = end }
                previous = character
                if length >= limit { break }
            }
            // A blank line (inside a packed model part) beats a sentence end; neither may leave a tiny fragment.
            if end < text.endIndex, let paragraphBreak, text[start..<paragraphBreak].utf16.count >= limit / 2 {
                end = paragraphBreak
            } else if end < text.endIndex, let preferred, text[start..<preferred].utf16.count >= limit / 2 {
                end = preferred
            }
            let part = text[start..<end]
            if let bodyStart = part.firstIndex(where: { !$0.isWhitespace }),
               let last = part.lastIndex(where: { !$0.isWhitespace }) {
                let bodyEnd = text.index(after: last)
                if start < bodyStart { result.append(.init(text: String(text[start..<bodyStart]), needsTranslation: false)) }
                result.append(.init(text: String(text[bodyStart..<bodyEnd]), needsTranslation: true))
                if bodyEnd < end { result.append(.init(text: String(text[bodyEnd..<end]), needsTranslation: false)) }
            } else {
                result.append(.init(text: String(part), needsTranslation: false))
            }
            start = end
        }
        return result
    }
}
