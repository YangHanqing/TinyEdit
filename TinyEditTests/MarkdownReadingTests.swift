import XCTest
import AppKit
@testable import TinyEdit

final class MarkdownReadingTests: XCTestCase {
    func testHeadingFragmentsChineseEncodingAndDuplicateCollisions() throws {
        let nodes = try MarkdownDocument.parse("# 安装\n\n# 安装\n\n# 安装-1\n\n# **Hello**, `World`!\n\n# Cafe\u{301}\n")
        let navigation = MarkdownNavigation(nodes)
        XCTAssertEqual(navigation.target(for: URL(string: "#安装")!)?.path, "0")
        XCTAssertEqual(navigation.target(for: URL(string: "#%E5%AE%89%E8%A3%85-1")!)?.path, "1")
        XCTAssertEqual(navigation.target(for: URL(string: "#安装-1-1")!)?.path, "2")
        XCTAssertEqual(navigation.target(for: URL(string: "#hello-world")!)?.path, "3")
        XCTAssertNotNil(navigation.target(for: URL(string: "#café")!))
        XCTAssertNil(navigation.target(for: URL(string: "other.md#安装")!))
        XCTAssertNil(navigation.target(for: URL(string: "https://example.com/#安装")!))
        XCTAssertNil(navigation.target(for: URL(string: "#不存在")!))
    }

    func testNestedHeadingPathsMatchViewTraversal() throws {
        let nodes = try MarkdownDocument.parse("# Start\n\n- item\n\n  > ## 深层\n\n> ## 末尾\n")
        let navigation = MarkdownNavigation(nodes)
        XCTAssertEqual(navigation.targets["深层"], .init(topLevel: 1, path: "1.0.1.0"))
        XCTAssertEqual(navigation.targets["末尾"], .init(topLevel: 2, path: "2.0"))
    }

    func testCodeFenceLanguagesAndSharedHighlightSpans() {
        XCTAssertEqual(MarkdownCode.language("JS"), .javascript)
        XCTAssertEqual(MarkdownCode.language("swift title=sample"), .swift)
        XCTAssertEqual(MarkdownCode.language("c++"), .cpp)
        XCTAssertEqual(MarkdownCode.language("unknown"), .plain)
        XCTAssertEqual(MarkdownCode.language(nil), .plain)
        let code = "{\"中文 👋\": true, \"value\": 42}"
        XCTAssertEqual(MarkdownCode.spans(code, hint: "json"), SyntaxHighlighter.spans(language: .json, text: code, limit: nil))
        XCTAssertTrue(MarkdownCode.spans(code, hint: "unknown").isEmpty)
        XCTAssertTrue(MarkdownCode.spans(String(repeating: "x", count: HighlightPolicy.fullLimit + 1), hint: "swift").isEmpty)
    }

    @MainActor func testCodeHighlightKeepsOriginalUnicodeText() {
        let code = "let value = \"中文 👋\"\n    print(value)\n"
        let styled = MarkdownCode.styled(code, spans: MarkdownCode.spans(code, hint: "swift"))
        XCTAssertEqual(styled.string, code)
        var colors: [NSColor] = []
        styled.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: styled.length)) { value, _, _ in
            if let color = value as? NSColor { colors.append(color) }
        }
        XCTAssertTrue(colors.contains { $0 !== Theme.textPrimary })
    }

    func testMixedFixtureRetainsNestedContentAndImageTable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("samples/markdown/compatibility.md"), encoding: .utf8)
        let nodes = try MarkdownDocument.parse(source)
        XCTAssertNotNil(MarkdownNavigation(nodes).targets["嵌套标题"])
        let table = try XCTUnwrap(nodes.compactMap { if case .table(let t) = $0 { return t }; return nil }.first)
        XCTAssertEqual(table.columns, [.leading, .center, .trailing])
        XCTAssertEqual(table.rows.count, 4)
        XCTAssertEqual(String(table.rows[0][0].characters), "标题\n第二行")
        XCTAssertTrue(table.rows[1][0].runs.contains { $0.imageURL != nil })
    }

    @MainActor func testFolderBookmarksSurviveSwitchAndNewAccessInstance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("grants.json")
        let document = root.appendingPathComponent("README.md")
        let access = MarkdownImageAccess(bookmarkFile: file)
        access.authorize(root, document: document)
        XCTAssertNil(access.authorizationMessage)
        let bookmarks = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: file))
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertNotNil(bookmarks[document.absoluteString])
        access.activate(document: root.appendingPathComponent("other.md"))
        access.activate(document: document)
        XCTAssertNil(access.authorizationMessage)
        access.reset()
        let reopened = MarkdownImageAccess(bookmarkFile: file)
        reopened.activate(document: document)
        XCTAssertNil(reopened.authorizationMessage)
        reopened.reset()
    }

    func testBreaksAndHTMLInsideStyledText() throws {
        let nodes = try MarkdownDocument.parse("**one<br>two** and <img src='a.png'> end")
        guard case .paragraph(let text) = nodes.first else { return XCTFail() }
        XCTAssertEqual(String(text.characters), "one\ntwo and \u{fffc} end")
        XCTAssertTrue(text.runs.contains { $0.imageURL?.relativeString == "a.png" })
    }
    @MainActor func testNativeHeadingJumpWaitsForAnchorAndAlignsToTop() async {
        final class FlippedView: NSView { override var isFlipped: Bool { true } }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 2000))
        let heading = NSView(frame: NSRect(x: 0, y: 900, width: 200, height: 30))
        document.addSubview(heading)
        scroll.documentView = document
        window.contentView = scroll
        let registry = MarkdownHeadingRegistry()
        registry.jump(to: "nested")
        registry.register(heading, path: "nested")
        let settled = expectation(description: "native layout jump")
        DispatchQueue.main.async { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 1)
        XCTAssertEqual(scroll.contentView.bounds.minY, 900, accuracy: 1)
        registry.reset()
        window.contentView = nil
    }

    func testLinkedImageKeepsItsDestination() throws {
        for source in ["[![alt](a.png)](#安装)", "[![**alt**](a.png)](#安装)"] {
            let nodes = try MarkdownDocument.parse(source)
            guard case .paragraph(let text) = nodes.first else { return XCTFail("\(nodes)") }
            let parts = MarkdownInline.parts(text)
            XCTAssertEqual(parts.count, 1)
            guard case .image(let image) = parts.first else { return XCTFail("\(nodes)") }
            XCTAssertEqual(image.link?.relativeString, "#%E5%AE%89%E8%A3%85")
            XCTAssertEqual(image.source.relativeString, "a.png")
        }
    }

}
