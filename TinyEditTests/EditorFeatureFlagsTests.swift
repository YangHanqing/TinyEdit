import XCTest
@testable import TinyEdit

final class EditorFeatureFlagsTests: XCTestCase {
    /// The checklist holds on the real text view once it is in a window, where AppKit may copy the user's
    /// global substitution defaults onto it.
    @MainActor
    func testPlainTextChecklistReachesTheTextView() {
        let settings = EditorSettings()
        let host = EditorTextHost()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host.scrollView
        host.activate(BufferTextStore(id: UUID(), text: "", settings: settings), settings: settings)
        let tv = host.textView
        XCTAssertFalse(tv.isRichText)
        XCTAssertFalse(tv.usesFontPanel)
        XCTAssertTrue(tv.allowsUndo)
        XCTAssertFalse(tv.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(tv.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(tv.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(tv.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(tv.isAutomaticLinkDetectionEnabled)
        XCTAssertFalse(tv.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(tv.isGrammarCheckingEnabled)
        XCTAssertEqual(tv.enabledTextCheckingTypes, 0)
        XCTAssertFalse(tv.smartInsertDeleteEnabled)
        XCTAssertFalse(tv.importsGraphics)
        withExtendedLifetime(window) {}
    }
    func testLineColumn() {
        let t = "ab\ncde\nf" as NSString
        XCTAssertEqual(LineColumn.compute(in: t, location: 0).line, 1)
        XCTAssertEqual(LineColumn.compute(in: t, location: 4).line, 2)
        XCTAssertEqual(LineColumn.compute(in: t, location: 4).column, 2)
        XCTAssertEqual(LineColumn.compute(in: t, location: 8).line, 3)
        let index = LineIndex.build(t as String, generation: 0)
        for loc in 0...t.length {
            XCTAssertTrue(LineColumn.compute(in: t, location: loc, index: index) == LineColumn.compute(in: t, location: loc))
        }
        let long = String(repeating: "x\n", count: LineColumn.maxScanLength) as NSString
        XCTAssertNil(LineColumn.compute(in: long, location: long.length).line)
        XCTAssertEqual(LineColumn.compute(in: long, location: long.length, index: LineIndex.build(long as String, generation: 0)).line,
                       LineColumn.maxScanLength + 1)
    }
    func testSettingsClamp() {
        var s = EditorSettings(); s.fontSize = 100; s.tabWidth = 0
        XCTAssertEqual(s.clamped().fontSize, 32); XCTAssertEqual(s.clamped().tabWidth, 1)
    }
    func testAppearanceRoundTripsAndDefaultsToDark() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "TinyEditTests.appearance"))
        d.removePersistentDomain(forName: "TinyEditTests.appearance")
        XCTAssertEqual(EditorSettings.load(from: d).appearance, .dark)
        var s = EditorSettings(); s.appearance = .system
        s.save(to: d)
        XCTAssertEqual(EditorSettings.load(from: d).appearance, .system)
        d.set("sepia", forKey: "tinyedit.appearance")
        XCTAssertEqual(EditorSettings.load(from: d).appearance, .dark)
    }
    func testBackgroundPatternDefaultsAndPersistsIncludingOff() throws {
        let suite = "TinyEditTests.backgroundPattern"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(EditorSettings.load(from: d).backgroundPattern, .dots)
        for pattern in BackgroundPattern.allCases {
            var s = EditorSettings()
            s.backgroundPattern = pattern
            s.save(to: d)
            XCTAssertEqual(EditorSettings.load(from: d).backgroundPattern, pattern)
        }
        d.set("unknown", forKey: "tinyedit.backgroundPattern")
        XCTAssertEqual(EditorSettings.load(from: d).backgroundPattern, .dots)
    }
    func testAppIconDefaultsAndPersists() throws {
        let suite = "TinyEditTests.appIcon"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(EditorSettings.load(from: d).appIcon, .notepad)
        for icon in AppIconStyle.allCases {
            var s = EditorSettings()
            s.appIcon = icon
            s.save(to: d)
            XCTAssertEqual(EditorSettings.load(from: d).appIcon, icon)
        }
        for (oldValue, newIcon) in ["night": AppIconStyle.code, "moon": .manuscript,
                                    "leaf": .manuscript, "sun": .notepad, "wave": .notepad,
                                    "quill": .manuscript, "paper": .notepad, "nib": .cursor, "lines": .cursor] {
            d.set(oldValue, forKey: "tinyedit.appIcon")
            XCTAssertEqual(EditorSettings.load(from: d).appIcon, newIcon)
        }
        d.set("unknown", forKey: "tinyedit.appIcon")
        XCTAssertEqual(EditorSettings.load(from: d).appIcon, .notepad)
    }
    @MainActor
    func testAppIconAssetsExist() {
        for icon in AppIconStyle.allCases {
            XCTAssertNotNil(NSImage(named: icon.imageName), icon.imageName)
        }
    }
}
