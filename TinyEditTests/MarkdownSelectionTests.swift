import XCTest
import AppKit
import SwiftUI
@testable import TinyEdit

/// Preview text must be selectable and copyable in every kind of block, tables and headings included.
@MainActor final class MarkdownSelectionTests: XCTestCase {
    private let source = """
    # Title One

    Paragraph with **bold**, *italic*, `code`, ~~gone~~ and [a link](https://example.com).

    ### Short

    - item one
    - [x] done item

    > quoted text

    | Left | Center | Right |
    | :--- | :---: | ---: |
    | cell one | cell two | 3 |

    ```swift
    let x = 1
    ```
    """

    func testInlineAttributesBecomeAppKitAttributes() throws {
        guard case .paragraph(let text) = try MarkdownDocument.parse(source)[1] else { return XCTFail() }
        let value = MarkdownText.attributed(text, style: .init(size: 13))
        XCTAssertEqual(value.string, "Paragraph with bold, italic, code, gone and a link.")
        func attributes(of word: String) -> [NSAttributedString.Key: Any] {
            value.attributes(at: (value.string as NSString).range(of: word).location, effectiveRange: nil)
        }
        let font = { (word: String) in attributes(of: word)[.font] as! NSFont }
        XCTAssertTrue(font("bold").fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(font("italic").fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertTrue(font("code").isFixedPitch)
        XCTAssertNotNil(attributes(of: "code")[.backgroundColor])
        XCTAssertNotNil(attributes(of: "gone")[.strikethroughStyle])
        XCTAssertEqual((attributes(of: "a link")[.link] as? URL)?.absoluteString, "https://example.com")
        XCTAssertFalse(font("Paragraph").fontDescriptor.symbolicTraits.contains(.bold))
        let secondary = MarkdownText.attributed(text, style: .init(size: 13, secondary: true))
        XCTAssertTrue(secondary.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor === Theme.textSecondary)
    }

    func testEveryPreviewBlockIsSelectableAndCopies() throws {
        let app = AppState.shared
        app.previewMessage = nil
        app.previewBlocks = try MarkdownDocument.parse(source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        defer { window.orderOut(nil); window.contentView = nil; app.previewBlocks = [] }
        let hosting = NSHostingView(rootView: MarkdownPreview().environment(app))
        window.contentView = hosting
        window.orderFront(nil)
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)); hosting.layoutSubtreeIfNeeded() }

        var views: [MarkdownSelectableTextView] = []
        var swiftUIText = 0
        func walk(_ view: NSView) {
            if let text = view as? MarkdownSelectableTextView { views.append(text) }
            if String(describing: type(of: view)).contains("TextInteraction") { swiftUIText += 1 }
            view.subviews.forEach(walk)
        }
        walk(hosting)
        XCTAssertEqual(swiftUIText, 0, "preview text left on SwiftUI Text")
        let strings = views.map(\.string)
        for expected in ["Title One", "Short", "item one", "done item", "quoted text", "Left", "cell two", "3", "let x = 1"] {
            XCTAssertTrue(strings.contains(expected), "\(expected) not in \(strings)")
        }

        let frame = try XCTUnwrap(window.contentView?.superview)
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer { pasteboard.clearContents(); if let saved { pasteboard.setString(saved, forType: .string) } }
        for view in views {
            XCTAssertFalse(view.mouseDownCanMoveWindow)
            XCTAssertGreaterThan(view.frame.height, 0, view.string)
            // The heading anchor and the table's scroller must not cover the text.
            let center = view.convert(NSPoint(x: min(6, view.bounds.midX), y: view.bounds.midY), to: nil)
            XCTAssertTrue(frame.hitTest(center) === view, "\(view.string) is covered by \(String(describing: frame.hitTest(center)))")
            view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
            pasteboard.clearContents()
            view.copy(nil)
            XCTAssertEqual(pasteboard.string(forType: .string), view.string)
        }

        // Wrapping text spans its row, so a drag can start past the end of a short line.
        let heading = try XCTUnwrap(views.first { $0.string == "Short" })
        XCTAssertEqual(heading.frame.width, 640 - 32, accuracy: 1)
        let code = try XCTUnwrap(views.first { $0.string == "let x = 1" })
        XCTAssertLessThan(code.frame.width, 200)
    }

    func testLongParagraphWrapsToItsWidth() {
        let text = AttributedString(String(repeating: "wrap me ", count: 60))
        let view = MarkdownSelectableTextView()
        view.setContent(MarkdownText.attributed(text, style: .init(size: 13)))
        let narrow = view.fittingSize(width: 200)
        let line = view.fittingSize(width: nil)
        XCTAssertEqual(narrow.width, 200)
        XCTAssertGreaterThan(narrow.height, line.height * 5)
        XCTAssertGreaterThan(line.width, 1000)
    }
}
