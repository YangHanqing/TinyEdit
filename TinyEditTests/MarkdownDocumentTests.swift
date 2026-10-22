import XCTest
@testable import TinyEdit

final class MarkdownDocumentTests: XCTestCase {
    private func text(_ s: String, _ intent: InlinePresentationIntent? = nil) -> AttributedString {
        var a = AttributedString(s)
        a.inlinePresentationIntent = intent
        return a
    }

    private func p(_ s: String) -> MarkdownNode { .paragraph(text(s)) }

    private func item(_ ordinal: Int, _ blocks: MarkdownNode...) -> MarkdownList.Item {
        MarkdownList.Item(ordinal: ordinal, blocks: blocks)
    }

    func testTopLevelBlocksInOrder() throws {
        let src = "# Head\n\nPara\n\n---\n\n```swift\nlet x = 1\n```\n\n    indented\n"
        XCTAssertEqual(try MarkdownDocument.parse(src), [
            .heading(level: 1, text: text("Head")),
            p("Para"),
            .thematicBreak,
            .codeBlock(language: "swift", code: "let x = 1"),
            .codeBlock(language: nil, code: "indented"),
        ])
    }

    func testInlineAttributesSurviveWithoutBlockIntent() throws {
        let blocks = try MarkdownDocument.parse("a **b** `c`")
        var expected = text("a ")
        expected += text("b", .stronglyEmphasized)
        expected += text(" ")
        expected += text("c", .code)
        XCTAssertEqual(blocks, [.paragraph(expected)])
    }

    func testTable() throws {
        let src = "| Name | Qty | Note |\n|:-----|----:|:----:|\n| apple | 3 | **red** |\n| pear |\n"
        XCTAssertEqual(try MarkdownDocument.parse(src), [.table(MarkdownTable(
            columns: [.leading, .trailing, .center],
            header: [text("Name"), text("Qty"), text("Note")],
            rows: [
                [text("apple"), text("3"), text("red", .stronglyEmphasized)],
                [text("pear"), AttributedString(), AttributedString()],
            ]
        ))])
    }

    func testListKindComesFromTheEnclosingList() throws {
        let src = "1. a\n   - b\n   - c\n2. d\n"
        XCTAssertEqual(try MarkdownDocument.parse(src), [.list(MarkdownList(ordered: true, items: [
            item(1, p("a"), .list(MarkdownList(ordered: false, items: [item(1, p("b")), item(2, p("c"))]))),
            item(2, p("d")),
        ]))])
    }

    func testListItemHoldsAllItsBlocks() throws {
        let src = "5. first\n\n   second\n\n   ```\n   code\n   ```\n6. six\n"
        XCTAssertEqual(try MarkdownDocument.parse(src), [.list(MarkdownList(ordered: true, items: [
            item(5, p("first"), p("second"), .codeBlock(language: nil, code: "code")),
            item(6, p("six")),
        ]))])
    }

    func testNestedQuotes() throws {
        let src = "> outer\n>> inner\n>\n> back\n"
        XCTAssertEqual(try MarkdownDocument.parse(src), [
            .blockQuote([p("outer"), .blockQuote([p("inner")]), p("back")]),
        ])
    }

    func testHTMLBlocksStayRaw() throws {
        let blocks = try MarkdownDocument.parse("<div>hi</div>\n\n> <div>q</div>\n")
        XCTAssertEqual(blocks, [.html("<div>hi</div>"), .blockQuote([.html("<div>q</div>")])])
    }

    func testImageReferencesArePreserved() throws {
        let blocks = try MarkdownDocument.parse("![alt](https://example.com/x.png)")
        guard case .paragraph(let alt) = blocks.first else { return XCTFail("\(blocks)") }
        XCTAssertEqual(String(alt.characters), "alt")
        XCTAssertEqual(alt.runs.first?.imageURL?.absoluteString, "https://example.com/x.png")
    }

    func testTaskItemsBecomeBoxes() throws {
        let blocks = try MarkdownDocument.parse("- [ ] open\n- [x] done\n- [X]\n- [ ]tight\n- plain\n\n1. [ ] first\n")
        XCTAssertEqual(blocks, [
            .list(MarkdownList(ordered: false, items: [
                MarkdownList.Item(ordinal: 1, blocks: [p("open")], task: false),
                MarkdownList.Item(ordinal: 2, blocks: [p("done")], task: true),
                MarkdownList.Item(ordinal: 3, blocks: [], task: true),
                item(4, p("[ ]tight")),
                item(5, p("plain")),
            ])),
            .list(MarkdownList(ordered: true, items: [MarkdownList.Item(ordinal: 1, blocks: [p("first")], task: false)])),
        ])
    }
}
