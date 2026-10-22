import Foundation

/// Line counts the line tools act on, with the same final-line-break rule as `TextTransform`.
struct LineStats: Equatable, Sendable {
    var lines = 0
    var duplicates = 0
    var blank = 0
    var trailingWhitespace = 0

    init(_ s: String) {
        guard !s.isEmpty else { return }
        let body = s.hasSuffix("\n") ? String(s.dropLast()) : s
        var seen = Set<String>()
        for line in body.components(separatedBy: "\n") {
            lines += 1
            if !seen.insert(line).inserted { duplicates += 1 }
            if line.allSatisfy(\.isWhitespace) { blank += 1 }
            if line.last?.isWhitespace == true { trailingWhitespace += 1 }
        }
    }
}

/// What a tool did, for the toast after it runs. Tools whose result is plain to see (a decode, a
/// format) report only when they changed nothing, so the user is not left wondering.
enum ToolFeedback: Equatable, Sendable {
    case removedInvisible(Int, [TextCleanup.InvisibleKind])
    case removedANSI(Int)
    case removedDuplicates(Int)
    case removedBlank(Int)
    case trimmed(Int)
    case sorted(Int)
    case reversed(Int)
    case shuffled(Int)
    case unchanged(TextTool)

    /// `input` is what the tool read, `output` what it produced (equal when nothing changed).
    static func make(_ tool: TextTool, input: String, output: String) -> ToolFeedback? {
        let changed = input != output
        switch tool {
        case .removeInvisibleCharacters:
            let report = TextCleanup.scan(input)
            return .removedInvisible(report.invisibleCount, report.invisible)
        case .removeANSIEscapes:
            return .removedANSI(TextCleanup.scan(input).ansiSequences)
        case .removeDuplicateLines:
            return .removedDuplicates(LineStats(input).lines - LineStats(output).lines)
        case .removeBlankLines:
            return .removedBlank(LineStats(input).lines - LineStats(output).lines)
        case .trimTrailingWhitespace:
            return .trimmed(LineStats(input).trailingWhitespace)
        case .sortLinesAscending, .sortLinesDescending:
            return changed ? .sorted(LineStats(input).lines) : .unchanged(tool)
        case .reverseLines:
            return changed ? .reversed(LineStats(input).lines) : .unchanged(tool)
        case .shuffleLines:
            return changed ? .shuffled(LineStats(input).lines) : .unchanged(tool)
        default:
            return changed ? nil : .unchanged(tool)
        }
    }
}

/// Palette commands that are not text tools.
enum PaletteCommandID {
    static let translateSelection = "translateSelection"
    static let translateDocument = "translateDocument"
    static let sendCurl = "sendCurl"
}

/// Where the palette was opened, gathered on the main thread for `ToolInsights.compute`.
struct PaletteContext: Equatable, Sendable {
    var language: EditorLanguage = .plain
    /// The tools run on the selection rather than the whole tab.
    var onSelection = false
    /// With nothing selected, the curl command around the caret (what Send curl Request would send).
    var curlAtCaret: String?
    /// The user's own language (`TranslationLanguages.canonical`); selected prose in another one may be worth translating.
    var nativeLanguage = "en"
}

/// What the command palette knows about the text the tools would run on, worked out when it opens:
/// which commands would do nothing here (dimmed), the likeliest few (Suggested), and how much each
/// cleanup or line tool would remove, before anything runs.
struct ToolInsights: Equatable, Sendable {
    /// Command ids, likeliest first, at most `maxSuggested`.
    var suggested: [String] = []
    /// For the tools that count what they act on. Zero means the tool would find nothing.
    var counts: [TextTool: Int] = [:]
    /// Command ids that would fail or change nothing here, found by running each transform on the real input.
    var disabled: Set<String> = []

    static let maxLength = PasteDecodeDetector.maxBytes
    static let maxSuggested = 3

    /// `text` is the selection or the whole tab; `lines` is the same widened to whole lines.
    static func compute(text: String, lines: String, context: PaletteContext = PaletteContext()) -> ToolInsights {
        var result = ToolInsights()
        let cleanup = TextCleanup.scan(text)
        let stats = LineStats(lines)
        result.counts = [
            .removeANSIEscapes: cleanup.ansiSequences,
            .removeInvisibleCharacters: cleanup.invisibleCount,
            .removeDuplicateLines: stats.duplicates,
            .removeBlankLines: stats.blank,
            .trimTrailingWhitespace: stats.trailingWhitespace,
        ]
        let ns = text as NSString
        let input = ns.substring(with: TextTransform.trimmedRange(NSRange(location: 0, length: ns.length), in: ns))

        // A JSON-looking text that does not parse keeps Format / Minify, which report where it breaks.
        let looksLikeJSON = input.first == "{" || input.first == "["
        let format = JSONFormatter.format(text: text, selection: nil)
        func jsonUseful(_ r: JSONFormatResult) -> Bool {
            switch r {
            case .formatted: true
            case .unchanged: false
            case .invalid: looksLikeJSON
            }
        }
        for tool in TextTool.allCases {
            let useful: Bool
            switch tool {
            case .formatJSON: useful = jsonUseful(format)
            case .minifyJSON: useful = jsonUseful(JSONFormatter.minify(text: text, selection: nil))
            case .shuffleLines: useful = stats.lines - stats.duplicates > 1
            default:
                if let count = result.counts[tool] {
                    useful = count > 0
                } else {
                    let source = tool.isLineTool ? lines : input
                    useful = !source.isEmpty && (try? TextTransform.apply(tool, to: source)).map { $0 != source } == true
                }
            }
            if !useful { result.disabled.insert(tool.id) }
        }
        let blank = input.isEmpty
        if !context.onSelection || blank || ns.length > TranslationPlan.inputLimit {
            result.disabled.insert(PaletteCommandID.translateSelection)
        }
        if !context.onSelection && (blank || ns.length > TranslationPlan.inputLimit) {
            result.disabled.insert(PaletteCommandID.translateDocument)
        }
        let curl = (context.onSelection ? input : context.curlAtCaret).flatMap(CurlCommand.parse)
        if curl == nil || curl?.unsupported != nil { result.disabled.insert(PaletteCommandID.sendCurl) }

        // Suggested, strongest signal first: what is wrong with the text, then what it plainly is,
        // then what the file type and the selection's shape say.
        var picks: [String] = []
        func suggest(_ id: String, if condition: Bool = true) {
            if condition, !result.disabled.contains(id), !picks.contains(id) { picks.append(id) }
        }
        suggest(TextTool.removeANSIEscapes.id)
        suggest(TextTool.removeInvisibleCharacters.id)
        suggest(PaletteCommandID.sendCurl)
        for candidate in PasteDecodeDetector.candidates(in: text) ?? [] { suggest(candidate.kind.tool.id) }
        if case .formatted = format { suggest(TextTool.formatJSON.id) }
        if context.language == .json, format == .unchanged { suggest(TextTool.minifyJSON.id) }
        // Prose in another language reads as "translate this"; a selected list of short lines as "sort it".
        let translate = context.onSelection ? PaletteCommandID.translateSelection : PaletteCommandID.translateDocument
        let foreign = [.plain, .markdown].contains(context.language) && looksLikeProse(input)
            && TranslationLanguages.detect(input).map { !TranslationLanguages.same($0, context.nativeLanguage) } == true
        let longLines = input.utf16.count >= 30 * max(stats.lines, 1)
        if longLines { suggest(translate, if: foreign) }
        if context.onSelection, stats.lines > 1 {
            // Repeated blank lines are not what "duplicates" means to the reader.
            suggest(TextTool.removeDuplicateLines.id, if: stats.duplicates > max(stats.blank - 1, 0))
            suggest(TextTool.sortLinesAscending.id)
        }
        suggest(translate, if: foreign)
        result.suggested = Array(picks.prefix(maxSuggested))
        return result
    }

    /// Words, not a token: three or more, or any ideograph.
    private static func looksLikeProse(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.isIdeographic } || s.split(maxSplits: 2, whereSeparator: \.isWhitespace).count == 3
    }
}

extension PasteDecodeKind {
    /// The Tools entry that does the same decode.
    var tool: TextTool {
        switch self {
        case .jwt: .decodeJWT
        case .jsonString: .unescapeJSONString
        case .base64: .base64Decode
        case .url: .urlDecode
        case .unicodeEscape: .unescapeUnicode
        case .timestamp: .timestampToDate
        }
    }
}
