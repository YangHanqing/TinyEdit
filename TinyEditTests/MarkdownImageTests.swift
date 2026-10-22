import XCTest
import AppKit
@testable import TinyEdit

final class MarkdownImageTests: XCTestCase {
    private func paragraph(_ source: String) throws -> AttributedString {
        let nodes = try MarkdownDocument.parse(source)
        guard case .paragraph(let text) = nodes.first else { XCTFail("No paragraph: \(nodes)"); return AttributedString() }
        return text
    }

    func testNativeImagesAndMixedTextKeepTheirOrder() throws {
        let parts = MarkdownInline.parts(try paragraph("Before ![one](a.png) after ![](b.png)"))
        XCTAssertEqual(parts.count, 4)
        guard case .image(let first) = parts[1], case .image(let second) = parts[3] else { return XCTFail() }
        XCTAssertEqual(first.source.relativeString, "a.png")
        XCTAssertEqual(first.alt, "one")
        XCTAssertEqual(second.source.relativeString, "b.png")
    }

    func testHTMLImagesAndBreaksWorkInsideTableCells() throws {
        let source = "| Preview | Details |\n| --- | --- |\n| <img src=\"assets/a&amp;b.png\" alt='Preview' width='560' height=\"400\" onerror='alert(1)'> | **Title**<br/>Body |"
        guard case .table(let table) = try MarkdownDocument.parse(source).first else { return XCTFail() }
        guard case .image(let image) = MarkdownInline.parts(table.rows[0][0]).first else { return XCTFail() }
        XCTAssertEqual(image.source.relativeString, "assets/a&b.png")
        XCTAssertEqual(image.alt, "Preview")
        XCTAssertEqual(image.dimensions, .init(width: 560, height: 400))
        XCTAssertEqual(String(table.rows[0][1].characters), "Title\nBody")
        XCTAssertTrue(table.rows[0][1].runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
    }

    func testNativeImageInsideTableAndEscapedPipes() throws {
        guard case .table(let table) = try MarkdownDocument.parse("| Image | Detail |\n| --- | --- |\n| ![demo](a.png) | one \\| two ~~old~~ |" ).first else { return XCTFail() }
        XCTAssertEqual(table.rows[0][0].runs.first?.imageURL?.relativeString, "a.png")
        XCTAssertEqual(String(table.rows[0][1].characters), "one | two old")
        XCTAssertTrue(table.rows[0][1].runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true })
    }

    func testStandaloneHTMLImagesAndQuotedGreaterThan() throws {
        let text = try paragraph("<IMG SRC='a.png' ALT='a > b' WIDTH=320>\n<img src=\"b.png\" />")
        let images = MarkdownInline.parts(text).compactMap { part -> MarkdownImageReference? in
            if case .image(let image) = part { return image }; return nil
        }
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images.first?.alt, "a > b")
        XCTAssertEqual(images.first?.dimensions.width, 320)
    }

    func testCodeAndUnknownHTMLAreNeverInterpreted() throws {
        let inline = try paragraph("`<img src='a.png'>` &lt;img src='b.png'&gt;")
        XCTAssertFalse(inline.runs.contains { $0.imageURL != nil })
        let nodes = try MarkdownDocument.parse("```html\n<img src='a.png'>\n<br>\n```\n\n<script>alert(1)</script>")
        guard case .codeBlock(_, let code) = nodes.first else { return XCTFail() }
        XCTAssertEqual(code, "<img src='a.png'>\n<br>")
        XCTAssertEqual(nodes.last, .html("<script>alert(1)</script>"))
    }

    func testDimensionsAndEntityDecodingAreBounded() throws {
        let parts = MarkdownInline.parts(try paragraph("<img src='a&#32;b.png' alt='&#x4E2D;&quot;' width='999999' height='-4'>"))
        guard case .image(let image) = parts.first else { return XCTFail() }
        XCTAssertEqual(image.source.lastPathComponent, "a b.png")
        XCTAssertEqual(image.alt, "中\"")
        XCTAssertEqual(image.dimensions.width, 4096)
        XCTAssertNil(image.dimensions.height)
    }

    func testRelativeImageResolutionUsesDocumentLocation() {
        let document = URL(fileURLWithPath: "/project/docs/README.md")
        XCTAssertEqual(MarkdownImageSource(URL(string: "../assets/a%20b.png")!, document: document),
                       .local(URL(fileURLWithPath: "/project/assets/a b.png")))
        XCTAssertEqual(MarkdownImageSource(URL(string: "a.png")!, document: nil), .unsaved)
        XCTAssertEqual(MarkdownImageSource(URL(string: "javascript:alert(1)")!, document: document), .unsupported)
        XCTAssertEqual(MarkdownImageSource(URL(string: "//tracker.example/image.png")!, document: document), .unsupported)
        let remote = URL(string: "https://example.com/a.png")!
        XCTAssertEqual(MarkdownImageSource(remote, document: document), .remote(remote))
    }

    @MainActor func testImagesFitTableColumnWithoutStretching() {
        let image = CGSize(width: 2200, height: 1440)
        let size = MarkdownImageView.fit(image, dimensions: .init(width: 560), available: 240)
        XCTAssertEqual(size.width, 240)
        XCTAssertEqual(size.height, 1440 * 240 / 2200, accuracy: 0.001)
        let heightBound = MarkdownImageView.fit(image, dimensions: .init(height: 100), available: 560)
        XCTAssertEqual(heightBound.height, 100)
        let small = MarkdownImageView.fit(CGSize(width: 40, height: 20), dimensions: .init(height: 100), available: 560)
        XCTAssertEqual(small, CGSize(width: 200, height: 100))
    }

    func testLocalImageDecodeAndInvalidFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = root.appendingPathComponent("a.png")
        try image.representation(using: .png, properties: [:])!.write(to: url)
        let decoded = try await MarkdownImageLoader.load(.local(url))
        XCTAssertEqual(decoded.width, 40)
        XCTAssertEqual(decoded.height, 20)
        try Data("<script>not an image</script>".utf8).write(to: url)
        do { _ = try await MarkdownImageLoader.load(.local(url)); XCTFail("HTML loaded as an image") }
        catch { XCTAssertEqual(error as? ImagePreviewFailure, .notImage) }
    }
}
