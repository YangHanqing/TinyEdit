import Foundation

/// Counts for the status bar while text is selected. Several selected ranges add up.
struct SelectionStats: Equatable, Sendable {
    /// User-perceived characters (grapheme clusters): an emoji family or an accented letter is one.
    /// Spaces and line breaks count.
    var characters = 0
    /// Words as word processors count them: a space-separated language by its words (found by the
    /// system's word breaker, which also splits Thai and similar scripts), Chinese and Japanese by
    /// each ideograph or kana. Punctuation and emoji are not words.
    var words = 0
    /// Lines touched. A range ending at the start of a line does not touch it.
    var lines = 0
    var utf8Bytes = 0

    /// Larger selections are counted off the main thread.
    static let synchronousLimit = 20_000

    init(characters: Int = 0, words: Int = 0, lines: Int = 0, utf8Bytes: Int = 0) {
        self.characters = characters
        self.words = words
        self.lines = lines
        self.utf8Bytes = utf8Bytes
    }

    init(_ pieces: [String]) {
        for piece in pieces where !piece.isEmpty {
            characters += piece.count
            utf8Bytes += piece.utf8.count
            words += Self.wordCount(piece)
            var breaks = piece.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            if piece.utf8.last == 0x0A { breaks -= 1 }
            lines += breaks + 1
        }
    }

    static func wordCount(_ s: String) -> Int {
        var count = 0
        s.enumerateSubstrings(in: s.startIndex..., options: .byWords) { word, _, _, _ in
            guard let word else { return }
            var ideographs = 0
            var other = false
            for scalar in word.unicodeScalars {
                if isIdeographOrKana(scalar) {
                    ideographs += 1
                } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                    other = true
                }
            }
            count += ideographs == 0 ? 1 : ideographs + (other ? 1 : 0)
        }
        return count
    }

    /// Hangul is not here: Korean separates words with spaces.
    private static func isIdeographOrKana(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: true   // hiragana, katakana, half-width katakana
        default: s.properties.isIdeographic
        }
    }
}
