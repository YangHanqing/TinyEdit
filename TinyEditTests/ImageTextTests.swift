import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import TinyEdit

/// Text read from pasted and dropped pictures: the layout rules, what a pasteboard holds, and the paste flow.
@MainActor
final class ImageTextTests: XCTestCase {
    // MARK: Layout

    /// A line `columns` characters in from the left, 10 px per character and 20 px per line, like a code screenshot.
    private func line(_ text: String, row: Double, columns: Int = 0, x: Double = 100, pitch: Double = 24) -> ImageTextLayout.Line {
        ImageTextLayout.Line(text: text, rect: CGRect(x: x + Double(columns) * 10, y: 50 + row * pitch,
                                                      width: Double(ImageTextLayout.displayColumns(text)) * 10, height: 20))
    }

    func testCodeKeepsIndentationAndBlankLines() {
        let lines = [
            line("func total() -> Int {", row: 0),
            line("var sum = 0", row: 1, columns: 4),
            line("for item in items {", row: 2, columns: 4),
            line("sum += item.price", row: 3, columns: 8),
            line("return sum", row: 5, columns: 4),   // row 4 was blank
        ]
        XCTAssertEqual(ImageTextLayout.text(lines: lines.shuffled(), indent: .spaces(4), tabWidth: 4), """
        func total() -> Int {
            var sum = 0
            for item in items {
                sum += item.price

            return sum
        """)
    }

    func testIndentationAsTabsWhenTheBufferUsesTabs() {
        let lines = [line("if x {", row: 0), line("y()", row: 1, columns: 4), line("z := 1", row: 2, columns: 10)]
        XCTAssertEqual(ImageTextLayout.text(lines: lines, indent: .tabs, tabWidth: 4), "if x {\n\ty()\n\t\t  z := 1")
    }

    /// Prose boxes start a pixel or two apart; that is not an indent.
    func testJitterIsNotIndentation() {
        let lines = [line("First line of a paragraph", row: 0), line("second line", row: 1, x: 104),
                     line("third line", row: 2, x: 97)]
        XCTAssertEqual(ImageTextLayout.text(lines: lines, indent: .spaces(4), tabWidth: 4),
                       "First line of a paragraph\nsecond line\nthird line")
    }

    func testPiecesOfOneRowJoinLeftToRight() {
        let lines = [
            ImageTextLayout.Line(text: "world", rect: CGRect(x: 170, y: 52, width: 50, height: 18)),
            ImageTextLayout.Line(text: "hello", rect: CGRect(x: 100, y: 50, width: 50, height: 20)),
            ImageTextLayout.Line(text: "a = 1", rect: CGRect(x: 100, y: 80, width: 50, height: 20)),
            ImageTextLayout.Line(text: "// note", rect: CGRect(x: 250, y: 81, width: 70, height: 20)),
        ]
        XCTAssertEqual(ImageTextLayout.text(lines: lines, indent: .spaces(4), tabWidth: 4),
                       "hello  world\na = 1" + String(repeating: " ", count: 10) + "// note")
    }

    func testCJKPiecesJoinWithoutASpace() {
        let lines = [
            ImageTextLayout.Line(text: "会话恢复", rect: CGRect(x: 100, y: 50, width: 80, height: 20)),
            ImageTextLayout.Line(text: "和持久化", rect: CGRect(x: 181, y: 50, width: 80, height: 20)),
        ]
        XCTAssertEqual(ImageTextLayout.text(lines: lines, indent: .spaces(4), tabWidth: 4), "会话恢复和持久化")
    }

    func testTablesBecomeTabSeparatedRowsInReadingOrder() {
        let table = ImageTextLayout.Table(rows: [["Name", "Price"], ["Apple", "3.50"], ["Ban\nana", "1.20"]],
                                          rect: CGRect(x: 100, y: 100, width: 300, height: 90))
        let lines = [
            line("Fruit report", row: 0),
            ImageTextLayout.Line(text: "Apple", rect: CGRect(x: 110, y: 130, width: 50, height: 20)),   // inside the table
            line("Total: 2", row: 9),
        ]
        XCTAssertEqual(ImageTextLayout.text(lines: lines, tables: [table], indent: .spaces(4), tabWidth: 4),
                       "Fruit report\n\nName\tPrice\nApple\t3.50\nBan ana\t1.20\n\nTotal: 2")
    }

    func testNothingRecognizedIsEmpty() {
        XCTAssertEqual(ImageTextLayout.text(lines: [line("  ", row: 0)], indent: .spaces(4), tabWidth: 4), "")
    }

    // MARK: Recognizer helpers

    func testLanguagesFollowTheUserThenChineseAndEnglish() {
        let supported = ["en-US", "fr-FR", "zh-Hans", "zh-Hant", "ja-JP"].map(Locale.Language.init(identifier:))
        let picked = ImageTextRecognizer.languages(preferred: ["ja-JP", "zh-Hant-TW", "en-GB"], supported: supported)
        XCTAssertEqual(picked, [supported[4], supported[3], supported[0], supported[2]])
    }

    func testDecodeAppliesOrientationAndCapsSize() throws {
        let sideways = try XCTUnwrap(Self.jpeg(width: 40, height: 20, orientation: .right))
        let upright = try XCTUnwrap(ImageTextRecognizer.decode(sideways))
        XCTAssertEqual([upright.width, upright.height], [20, 40])
        let wide = try XCTUnwrap(Self.jpeg(width: ImageTextRecognizer.maxPixelSize + 800, height: 10))
        XCTAssertEqual(try XCTUnwrap(ImageTextRecognizer.decode(wide)).width, ImageTextRecognizer.maxPixelSize)
        XCTAssertNil(ImageTextRecognizer.decode(Data("not an image".utf8)))
    }

    /// A blank JPEG of the stored size, with an EXIF orientation.
    private static func jpeg(width: Int, height: Int, orientation: CGImagePropertyOrientation = .up) -> Data? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: Pasteboard

    private func withPasteboard(_ fill: (NSPasteboard) -> Void, _ check: (NSPasteboard) throws -> Void) rethrows {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        fill(pb)
        try check(pb)
    }

    /// Screenshot tools like Snapzy write the file with `writeObjects` (which adds the legacy filename and URL
    /// types) and then the pixels: the file wins.
    func testFileReferenceWinsOverPixelsAndItsPath() {
        let url = URL(fileURLWithPath: "/tmp/Screenshot 2026.png")
        withPasteboard({ pb in
            pb.writeObjects([url as NSURL])
            pb.addTypes([.png], owner: nil)
            pb.setData(Data([1, 2, 3]), forType: .png)
        }) { pb in
            XCTAssertEqual(PastedImage.content(of: pb), .files([url]))
        }
    }

    func testPixelsAloneAreAnImage() {
        withPasteboard({ $0.setData(Data([1, 2, 3]), forType: .tiff) }) { pb in
            XCTAssertEqual(PastedImage.content(of: pb), .image(Data([1, 2, 3])))
        }
    }

    /// Spreadsheets and slides put text and a picture of it on the pasteboard together.
    func testTextWinsOverPixels() {
        withPasteboard({ pb in
            pb.declareTypes([.string, .png], owner: nil)
            pb.setString("A1\tB1", forType: .string)
            pb.setData(Data([1]), forType: .png)
        }) { pb in
            XCTAssertEqual(PastedImage.content(of: pb), .other)
        }
    }

    func testImageFilesByType() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ImageTextTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.png", "b.JPG", "c.heic", "d.webp"] {
            XCTAssertTrue(PastedImage.isImageFile(dir.appendingPathComponent(name)), name)
        }
        for name in ["e.svg", "f.txt", "g.pdf"] {
            XCTAssertFalse(PastedImage.isImageFile(dir.appendingPathComponent(name)), name)
        }
        XCTAssertFalse(PastedImage.isImageFile(dir))
    }

    func testSettingRoundTrips() {
        let d = UserDefaults(suiteName: "ImageTextTests-\(UUID().uuidString)")!
        XCTAssertTrue(EditorSettings.load(from: d).recognizeTextInImages)
        var s = EditorSettings()
        s.recognizeTextInImages = false
        s.save(to: d)
        XCTAssertFalse(EditorSettings.load(from: d).recognizeTextInImages)
    }

    // MARK: Paste flow

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ImageTextIT-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func launch() async -> AppState {
        let s = AppState(root: root, autoRestore: false)
        await s.restore()
        s.host.activate(s.activeStore!, settings: s.settings)
        return s
    }

    /// What `EditorTextView.paste(_:)` does, on a private pasteboard so the user's clipboard is untouched.
    private func paste(into s: AppState, _ fill: (NSPasteboard) -> Void) -> Bool {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        fill(pb)
        s.beginPasteRecognition()
        defer { s.endPasteRecognition() }
        return s.handlePasteboard(pb)
    }

    private func waitFor(_ timeout: Duration = .seconds(60), _ condition: () -> Bool) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// A copied file that is not a picture pastes its path, not a `file://` URL.
    func testPastedFileReferenceInsertsItsPath() async throws {
        let s = await launch()
        let files = [URL(fileURLWithPath: "/tmp/notes one.txt"), URL(fileURLWithPath: "/tmp/b.png")]
        XCTAssertTrue(paste(into: s) { $0.writeObjects(files.map { $0 as NSURL }) })
        XCTAssertEqual(s.activeStore?.logicalString(), "/tmp/notes one.txt\n/tmp/b.png")
        XCTAssertNil(s.selectedBuffer?.imageText)
        s.activeStore?.undoManager.undo()
        XCTAssertEqual(s.activeStore?.logicalString(), "")
    }

    func testPastedPictureInsertsItsTextAsOneUndoStep() async throws {
        let s = await launch()
        s.activeStore!.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "before ")
        s.host.textView.setSelectedRange(NSRange(location: 7, length: 0))
        let png = try XCTUnwrap(Self.picture(of: "Hello TinyEdit 2026", pointSize: 40))
        XCTAssertTrue(paste(into: s) { $0.setData(png, forType: .png) })
        XCTAssertEqual(s.selectedBuffer?.imageText, .recognizing)
        let inserted = await waitFor { s.activeStore?.logicalString().contains("TinyEdit") == true }
        XCTAssertTrue(inserted, s.activeStore?.logicalString() ?? "")
        XCTAssertTrue(s.activeStore!.logicalString().hasPrefix("before Hello"))
        XCTAssertNil(s.selectedBuffer?.imageText)
        s.activeStore?.undoManager.undo()
        XCTAssertEqual(s.activeStore?.logicalString(), "before ")
    }

    /// Typing while the picture is read: the text is offered, not dropped into the middle of the typing.
    func testEditDuringRecognitionOffersTheText() async throws {
        let s = await launch()
        let png = try XCTUnwrap(Self.picture(of: "Offered later", pointSize: 40))
        XCTAssertTrue(paste(into: s) { $0.setData(png, forType: .png) })
        s.host.textView.insertText("typed", replacementRange: NSRange(location: 0, length: 0))
        let offered = await waitFor { if case .offer = s.selectedBuffer?.imageText { true } else { false } }
        XCTAssertTrue(offered)
        XCTAssertEqual(s.activeStore?.logicalString(), "typed")
        guard case .offer(let text) = s.selectedBuffer?.imageText else { return }
        XCTAssertTrue(text.contains("Offered"), text)
        s.insertRecognizedText()
        XCTAssertEqual(s.activeStore?.logicalString(), "typed" + text)
        XCTAssertNil(s.selectedBuffer?.imageText)
    }

    func testCancelStopsRecognition() async throws {
        let s = await launch()
        let png = try XCTUnwrap(Self.picture(of: "Never inserted", pointSize: 40))
        XCTAssertTrue(paste(into: s) { $0.setData(png, forType: .png) })
        XCTAssertTrue(s.cancelImageTextFromEscape())
        XCTAssertNil(s.selectedBuffer?.imageText)
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(s.activeStore?.logicalString(), "")
        XCTAssertNil(s.selectedBuffer?.imageText)
    }

    func testRecognitionOffLeavesPicturesToAppKit() async throws {
        let s = await launch()
        var settings = s.settings
        settings.recognizeTextInImages = false
        s.updateSettings(settings)
        defer { var on = s.settings; on.recognizeTextInImages = true; s.updateSettings(on) }
        XCTAssertFalse(paste(into: s) { $0.setData(Data([1]), forType: .png) })
        XCTAssertTrue(paste(into: s) { $0.writeObjects([URL(fileURLWithPath: "/tmp/shot.png") as NSURL]) })
        XCTAssertEqual(s.activeStore?.logicalString(), "/tmp/shot.png")
    }

    /// Black text on white, as a PNG at 2x.
    static func picture(of text: String, pointSize: CGFloat) -> Data? {
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: pointSize),
                                                                       .foregroundColor: NSColor.black])
        let size = attributed.size()
        let width = Int(size.width) + 80, height = Int(size.height) + 80
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        attributed.draw(at: NSPoint(x: 40, y: 40))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
