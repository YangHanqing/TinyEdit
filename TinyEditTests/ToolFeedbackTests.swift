import XCTest
@testable import TinyEdit

final class ToolFeedbackTests: XCTestCase {
    private func feedback(_ tool: TextTool, _ input: String) throws -> ToolFeedback? {
        ToolFeedback.make(tool, input: input, output: try TextTransform.apply(tool, to: input))
    }

    func testCountsWhatWasRemoved() throws {
        XCTAssertEqual(try feedback(.removeInvisibleCharacters, "a\u{200B}b\u{200B}\u{202E}"),
                       .removedInvisible(3, [.init(value: 0x200B, count: 2), .init(value: 0x202E, count: 1)]))
        XCTAssertEqual(try feedback(.removeInvisibleCharacters, "clean"), .removedInvisible(0, []))
        XCTAssertEqual(try feedback(.removeANSIEscapes, "\u{1B}[1mx\u{1B}[0m"), .removedANSI(2))
        XCTAssertEqual(try feedback(.removeDuplicateLines, "a\nb\na\na\n"), .removedDuplicates(2))
        XCTAssertEqual(try feedback(.removeBlankLines, "a\n\n  \nb"), .removedBlank(2))
        XCTAssertEqual(try feedback(.trimTrailingWhitespace, "a \nb\nc\t"), .trimmed(2))
        XCTAssertEqual(try feedback(.trimTrailingWhitespace, "a\nb"), .trimmed(0))
    }

    func testReorderingReportsLinesOrUnchanged() throws {
        XCTAssertEqual(try feedback(.sortLinesAscending, "b\na\nc\n"), .sorted(3))
        XCTAssertEqual(try feedback(.sortLinesAscending, "a\nb"), .unchanged(.sortLinesAscending))
        XCTAssertEqual(try feedback(.reverseLines, "a\nb"), .reversed(2))
    }

    /// A decode's result is visible, so only "nothing changed" is reported.
    func testOtherToolsReportOnlyWhenUnchanged() throws {
        XCTAssertNil(try feedback(.base64Encode, "hi"))
        XCTAssertEqual(try feedback(.urlEncode, "plain"), .unchanged(.urlEncode))
    }

    func testInsights() {
        // Format JSON is not offered until the cleanups have made the text parse.
        let insights = ToolInsights.compute(text: "\u{1B}[32m{\"a\":1}\u{1B}[0m\u{200B}", lines: "x\nx\n\ny \n")
        XCTAssertEqual(insights.suggested, ["removeANSIEscapes", "removeInvisibleCharacters"])
        XCTAssertEqual(insights.counts[.removeANSIEscapes], 2)
        XCTAssertEqual(insights.counts[.removeInvisibleCharacters], 1)
        XCTAssertEqual(insights.counts[.removeDuplicateLines], 1)
        XCTAssertEqual(insights.counts[.removeBlankLines], 1)
        XCTAssertEqual(insights.counts[.trimTrailingWhitespace], 1)
        XCTAssertEqual(ToolInsights.compute(text: "SGVsbG8gd29ybGQ=", lines: "SGVsbG8gd29ybGQ=").suggested, ["base64Decode"])
        XCTAssertEqual(ToolInsights.compute(text: "just prose", lines: "just prose").suggested, [])
    }

    /// A command is disabled exactly when its transform would fail or change nothing on this input.
    func testDisabledCommands() {
        let prose = ToolInsights.compute(text: "just prose", lines: "just prose")
        for tool: TextTool in [.formatJSON, .minifyJSON, .unescapeJSONString, .base64Decode, .urlDecode, .unescapeUnicode,
                               .decodeJWT, .timestampToDate, .sortLinesAscending, .reverseLines, .shuffleLines,
                               .removeDuplicateLines, .removeBlankLines, .trimTrailingWhitespace,
                               .removeANSIEscapes, .removeInvisibleCharacters] {
            XCTAssertTrue(prose.disabled.contains(tool.id), tool.id)
        }
        for tool: TextTool in [.escapeJSONString, .base64Encode, .urlEncode] {
            XCTAssertFalse(prose.disabled.contains(tool.id), tool.id)
        }
        XCTAssertTrue(prose.disabled.isSuperset(of: [PaletteCommandID.translateSelection, PaletteCommandID.sendCurl]))
        XCTAssertFalse(prose.disabled.contains(PaletteCommandID.translateDocument))

        let empty = ToolInsights.compute(text: "", lines: "")
        XCTAssertTrue(empty.disabled.isSuperset(of: Set(TextTool.allCases.map(\.id) + [PaletteCommandID.translateDocument])))

        // Broken JSON keeps Format and Minify, which say where it breaks.
        let broken = ToolInsights.compute(text: "{\"a\": }", lines: "{\"a\": }")
        XCTAssertFalse(broken.disabled.contains(TextTool.formatJSON.id))
        XCTAssertFalse(broken.disabled.contains(TextTool.minifyJSON.id))

        let sorted = ToolInsights.compute(text: "a\nb\nc\n", lines: "a\nb\nc\n", context: PaletteContext(onSelection: true))
        XCTAssertTrue(sorted.disabled.contains(TextTool.sortLinesAscending.id))
        XCTAssertFalse(sorted.disabled.contains(TextTool.sortLinesDescending.id))
        XCTAssertFalse(sorted.disabled.contains(PaletteCommandID.translateSelection))
    }

    func testSuggestionsFollowTheFileAndTheSelection() {
        let compact = #"{"a":1,"b":[2]}"#
        let pretty = "{\n  \"a\": 1\n}"
        XCTAssertEqual(ToolInsights.compute(text: compact, lines: compact, context: PaletteContext(language: .json)).suggested, ["formatJSON"])
        XCTAssertEqual(ToolInsights.compute(text: pretty, lines: pretty, context: PaletteContext(language: .json)).suggested, ["minifyJSON"])
        XCTAssertEqual(ToolInsights.compute(text: pretty, lines: pretty).suggested, [])

        let list = "pear\napple\npear\n"
        XCTAssertEqual(ToolInsights.compute(text: list, lines: list, context: PaletteContext(onSelection: true)).suggested,
                       ["removeDuplicateLines", "sortLinesAscending"])
        XCTAssertEqual(ToolInsights.compute(text: list, lines: list).suggested, [])
        let blanks = "b\n\na\n\nc\n"                                   // repeated blank lines are not duplicates
        XCTAssertEqual(ToolInsights.compute(text: blanks, lines: blanks, context: PaletteContext(onSelection: true)).suggested,
                       ["sortLinesAscending"])

        let curl = "curl https://example.com/api -H 'Accept: application/json'"
        let caret = ToolInsights.compute(text: "x\n" + curl, lines: "x\n" + curl, context: PaletteContext(curlAtCaret: curl))
        XCTAssertEqual(caret.suggested.first, PaletteCommandID.sendCurl)
        XCTAssertTrue(ToolInsights.compute(text: "x", lines: "x").disabled.contains(PaletteCommandID.sendCurl))

        let english = "The quick brown fox jumps over the lazy dog while the farmer watches from the porch."
        var context = PaletteContext(onSelection: true, nativeLanguage: "zh-Hans")
        XCTAssertEqual(ToolInsights.compute(text: english, lines: english, context: context).suggested, [PaletteCommandID.translateSelection])
        context.onSelection = false
        XCTAssertEqual(ToolInsights.compute(text: english, lines: english, context: context).suggested, [PaletteCommandID.translateDocument])
        context.nativeLanguage = "en"
        XCTAssertEqual(ToolInsights.compute(text: english, lines: english, context: context).suggested, [])
        context = PaletteContext(language: .swift, nativeLanguage: "zh-Hans")
        XCTAssertEqual(ToolInsights.compute(text: english, lines: english, context: context).suggested, [])
    }

    func testSuggestionsStopAtThree() {
        let text = "\u{1B}[1mx\u{1B}[0m\u{200B}\nb\nb\na"
        let insights = ToolInsights.compute(text: text, lines: text, context: PaletteContext(onSelection: true))
        XCTAssertEqual(insights.suggested, ["removeANSIEscapes", "removeInvisibleCharacters", "removeDuplicateLines"])
    }

    func testPaletteSections() {
        let commands = TextTool.allCases.map {
            PaletteCommand(id: $0.id, title: $0.title, englishTitle: $0.englishTitle, keywords: $0.keywords,
                           category: $0.group.title) {}
        }
        let sections = PaletteSection.make(commands, suggested: ["removeInvisibleCharacters", "missing"])
        XCTAssertEqual(sections.map(\.id), ["suggested"] + TextToolGroup.allCases.map { "group." + $0.title })
        XCTAssertEqual(sections[0].commands.map(\.id), ["removeInvisibleCharacters"])
        XCTAssertEqual(sections.dropFirst().flatMap(\.commands).map(\.id), TextTool.allCases.map(\.id))
        XCTAssertEqual(PaletteSection.make(commands, suggested: []).first?.id, "group.JSON")
    }

    /// Disabled commands sink within their group, a group with nothing enabled sinks to the end,
    /// and a disabled command is never suggested.
    func testPaletteSectionsSinkDisabledCommands() {
        let enabled: Set<TextTool> = [.escapeJSONString, .base64Encode, .trimTrailingWhitespace]
        let commands = TextTool.allCases.map {
            var c = PaletteCommand(id: $0.id, title: $0.title, englishTitle: $0.englishTitle, keywords: $0.keywords,
                                   category: $0.group.title) {}
            c.enabled = enabled.contains($0)
            return c
        }
        let sections = PaletteSection.make(commands, suggested: ["formatJSON", "base64Encode"])
        XCTAssertEqual(sections.map(\.id), ["suggested", "group." + TextToolGroup.json.title, "group." + TextToolGroup.encoding.title,
                                            "group." + TextToolGroup.cleanup.title, "group." + TextToolGroup.lines.title])
        XCTAssertEqual(sections[0].commands.map(\.id), ["base64Encode"])
        XCTAssertEqual(sections[1].commands.map(\.id), ["escapeJSONString", "formatJSON", "minifyJSON", "unescapeJSONString"])
        XCTAssertEqual(PaletteCommand.filter(commands, query: "json").map(\.id).first, "escapeJSONString")
    }
}
