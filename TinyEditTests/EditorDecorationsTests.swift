import XCTest
import AppKit
import SwiftUI
@testable import TinyEdit

@MainActor
final class EditorDecorationsTests: XCTestCase {
    private let text = """
    ## 开发部署

    ```bash
    # 安装依赖
    npm install

    # 启动开发服务器
    npm run dev

    # 构建生产版本
    npm run build
    ```
    """

    func testOccurrenceBackgroundsCoverMatchingGlyphs() throws {
        try checkOccurrenceBackgrounds(documentOrigin: .zero, wrap: true)
    }

    /// NSClipView adjusts its bounds when its document's origin moves, keeping the text at the same
    /// screen position. Painting document coordinates directly in the clip then shifts the backgrounds.
    func testOccurrenceBackgroundsCoverGlyphsWithDifferentDocumentAndClipOrigins() throws {
        try checkOccurrenceBackgrounds(documentOrigin: NSPoint(x: -64, y: 0), wrap: true)
    }

    func testOccurrenceBackgroundsCoverUnwrappedGlyphsAfterScrolling() throws {
        try checkOccurrenceBackgrounds(documentOrigin: NSPoint(x: -64, y: 24), wrap: false, scroll: true)
    }

    private func checkOccurrenceBackgrounds(documentOrigin: NSPoint, wrap: Bool, scroll: Bool = false) throws {
        var settings = EditorSettings()
        settings.wordWrap = wrap
        let host = EditorTextHost()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 493, height: 230),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let source = scroll ? String(repeating: "prefix line\n", count: 43) + text + String(repeating: "\nsuffix line", count: 30) : text
        let store = BufferTextStore(id: UUID(), text: source, settings: settings)
        window.contentView = NSHostingView(rootView: EditorView(host: host, store: store, allStores: [store], settings: settings))
        host.activate(store, settings: settings)
        host.backgroundView.pattern = .off
        window.appearance = NSAppearance(named: .darkAqua)
        let matches = FindMatches.ranges(of: "npm", in: source as NSString, caseSensitive: true).ranges
        XCTAssertEqual(matches.count, 3)
        host.textView.setSelectedRange(matches[0])
        settle(window)
        for span in SyntaxHighlighter.spans(language: .markdown, text: source, limit: nil) {
            if let range = store.contentStorage.textRange(for: span.range) {
                host.layoutManager.addRenderingAttribute(.foregroundColor, value: span.kind.color, for: range)
            }
        }
        host.redrawVisibleText()
        if scroll {
            let clip = host.backgroundView
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: 43 * 16))
            host.scrollView.reflectScrolledClipView(clip)
            settle(window)
        }
        host.textView.updateOverlays()
        XCTAssertEqual(host.textView.currentDecorations.occurrences.count, 2)
        // Deliberately exercise the coordinate assumption, rather than depending on AppKit to move the
        // document view on this machine. The clip keeps its normal scroll position relative to the text.
        host.textView.setFrameOrigin(documentOrigin)
        let view = host.scrollView
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let suffix = wrap ? (documentOrigin == .zero ? "normal" : "translated") : "scrolled"
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)   // kept in the result only when the test fails
        attachment.name = "Occurrence backgrounds (\(suffix))"
        add(attachment)

        let scaleX = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        for match in matches.dropFirst() {
            // NSTextView's native character rect is independent of the decoration painting code.
            let screenRect = host.textView.firstRect(forCharacterRange: match, actualRange: nil)
            let glyphRect = view.convert(window.convertFromScreen(screenRect), from: nil)
            let x = Int((glyphRect.midX - view.bounds.minX) * scaleX)
            let top = glyphRect.minY + 1.5
            let y = Int((view.isFlipped ? top - view.bounds.minY : view.bounds.maxY - top) * scaleY)
            XCTAssertTrue((0..<bitmap.pixelsWide).contains(x) && (0..<bitmap.pixelsHigh).contains(y))
            guard (0..<bitmap.pixelsWide).contains(x), (0..<bitmap.pixelsHigh).contains(y) else { continue }
            let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            let plainX = min(x + Int(150 * scaleX), bitmap.pixelsWide - Int(40 * scaleX))
            let plain = try XCTUnwrap(bitmap.colorAt(x: plainX, y: y)?.usingColorSpace(.deviceRGB))
            // Compare pixels from the same image so display color profiles cannot affect the check.
            XCTAssertGreaterThan(pixel.redComponent - plain.redComponent, 0.06, "background misses npm at \(match)")
            XCTAssertGreaterThan(pixel.greenComponent - plain.greenComponent, 0.06)
            XCTAssertGreaterThan(pixel.blueComponent - plain.blueComponent, 0.06)
        }
    }

    func testJSONPictureIconsSitAfterTheirLines() throws {
        let settings = EditorSettings()
        let host = EditorTextHost()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 230),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let source = """
        {
          "avatar": "https://x.test/a.png",
          "name": "Ada",
          "pair": ["https://x.test/b.png", "https://x.test/c.png"]
        }
        """
        let store = BufferTextStore(id: UUID(), text: source, settings: settings)
        window.contentView = NSHostingView(rootView: EditorView(host: host, store: store, allStores: [store], settings: settings))
        host.activate(store, settings: settings)
        let images = JSONLocator.valueMarks(in: Array(source.utf16)).filter(\.isImage)
        XCTAssertEqual(images.count, 3)
        host.textView.jsonValueMarks = { images }
        settle(window)
        host.textView.updateOverlays()
        var marks = host.textView.currentDecorations.valueMarks
        XCTAssertEqual(marks.map(\.valueRange), [images[0].valueRange, images[1].valueRange])   // one per line, the first
        let ns = source as NSString
        for mark in marks {
            let line = ns.lineRange(for: mark.valueRange)
            let end = try XCTUnwrap(host.textView.segmentRect(NSRange(location: NSMaxRange(line) - 2, length: 1)))
            XCTAssertGreaterThan(mark.rect.minX, end.maxX)                                        // after the comma
            XCTAssertLessThan(mark.rect.minX - end.maxX, 16)
            XCTAssertTrue(mark.rect.intersects(NSRect(x: 0, y: end.minY, width: 1e4, height: end.height)))
            XCTAssertEqual(mark.kind, .image)
            XCTAssertEqual(host.textView.valueMark(at: NSPoint(x: mark.rect.midX, y: mark.rect.midY))?.valueRange,
                           mark.valueRange)
        }

        host.textView.setSelectedRange(NSRange(location: images[2].valueRange.location + 3, length: 0))
        host.textView.updateOverlays()
        marks = host.textView.currentDecorations.valueMarks
        XCTAssertEqual(marks.last?.valueRange, images[2].valueRange)                               // the caret's value
        host.textView.jsonValueMarks = { [] }
        host.textView.updateOverlays()
        XCTAssertEqual(host.textView.currentDecorations.valueMarks, [])
    }

    func testJSONLinkColorAndTimeMarks() throws {
        let settings = EditorSettings()
        let host = EditorTextHost()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 230),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let source = """
        {
          "home": "https://x.test/",
          "fg": "#ff8800",
          "created": 1700000000
        }
        """
        let store = BufferTextStore(id: UUID(), text: source, settings: settings)
        window.contentView = NSHostingView(rootView: EditorView(host: host, store: store, allStores: [store], settings: settings))
        host.activate(store, settings: settings)
        let values = JSONLocator.valueMarks(in: Array(source.utf16))
        host.textView.jsonValueMarks = { values }
        settle(window)
        host.textView.updateOverlays()
        let decorations = host.textView.currentDecorations
        guard case .size = decorations.valueMarks.first?.kind else { return XCTFail("no size on the first line") }
        XCTAssertNil(host.textView.valueMark(at: NSPoint(x: decorations.valueMarks[0].rect.midX,
                                                         y: decorations.valueMarks[0].rect.midY)))   // a size takes no click
        let marks = Array(decorations.valueMarks.dropFirst())
        let time = JSONValueInsight.dateText(Date(timeIntervalSince1970: 1_700_000_000), milliseconds: false)
        XCTAssertEqual(marks.map(\.kind), [.link, .color(JSONColor(red: 1, green: 136.0 / 255, blue: 0, alpha: 1)), .time(time)])
        let font = try XCTUnwrap(decorations.markFont)
        XCTAssertGreaterThanOrEqual(marks[2].rect.width, (time as NSString).size(withAttributes: [.font: font]).width)
        // The swatch only shows the color; the link and the time take clicks.
        XCTAssertEqual(host.textView.valueMark(at: NSPoint(x: marks[0].rect.midX, y: marks[0].rect.midY))?.valueRange,
                       marks[0].valueRange)
        XCTAssertNil(host.textView.valueMark(at: NSPoint(x: marks[1].rect.midX, y: marks[1].rect.midY)))
        XCTAssertEqual(host.textView.valueMark(at: NSPoint(x: marks[2].rect.midX, y: marks[2].rect.midY))?.valueRange,
                       marks[2].valueRange)

        // Settings hide marks without a new scan.
        host.textView.decorationOptions.jsonMarks.links = false
        host.textView.decorationOptions.jsonMarks.sizes = false
        host.textView.updateOverlays()
        XCTAssertEqual(host.textView.currentDecorations.valueMarks.map(\.valueRange), [marks[1].valueRange, marks[2].valueRange])
    }

    private func settle(_ window: NSWindow) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.displayIfNeeded()
    }
}
