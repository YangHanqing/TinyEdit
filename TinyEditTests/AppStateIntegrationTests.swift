import XCTest
import AppKit
@testable import TinyEdit

/// Drives real AppState instances against a temp root: recovery, restore, open, save, conflicts.
@MainActor
final class AppStateIntegrationTests: XCTestCase {
    var root: URL!
    var files: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TinyEditIT-\(UUID().uuidString)")
        root = base.appendingPathComponent("root")
        files = base.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    private func launch() async -> AppState {
        let s = AppState(root: root, autoRestore: false)
        await s.restore()
        return s
    }

    private func type(_ text: String, into s: AppState, at id: UUID? = nil) {
        let store = s.stores[id ?? s.session.selectedBufferID!]!
        store.textStorage.replaceCharacters(in: NSRange(location: store.length, length: 0), with: text)
    }

    func testStatusBarCountsTasksAfterTheEditPause() async throws {
        let s = await launch()
        s.setLanguage(.markdown)
        type("- [ ] a\n- [x] b\n```\n- [ ] code\n```", into: s)
        let expected = TaskList.Counts(done: 1, total: 2)
        for _ in 0..<40 where s.status.tasks != expected { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(s.status.tasks, expected)
        s.setLanguage(.json)
        XCTAssertNil(s.status.tasks)
        s.setLanguage(.plain)   // Plain Text has no fences: the fenced task counts too
        for _ in 0..<40 where s.status.tasks?.total != 3 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(s.status.tasks, TaskList.Counts(done: 1, total: 3))
    }

    func testFreshLaunchHasOneUntitledAndGateOpen() async {
        let s = await launch()
        XCTAssertTrue(s.launchGateOpen)
        XCTAssertEqual(s.session.orderedBuffers.map(\.title), ["Untitled"])
    }

    func testFiveUntitledTabsSurviveQuitAndRelaunch() async {
        let a = await launch()
        type("one", into: a)
        for i in 2...5 { a.newTab(); type("text \(i)", into: a) }
        let order = a.session.tabOrder
        let selected = a.session.selectedBufferID
        await a.performFlush()

        let b = await launch()
        XCTAssertEqual(b.session.tabOrder, order)
        XCTAssertEqual(b.session.selectedBufferID, selected)
        XCTAssertEqual(b.stores[order[0]]?.logicalString(), "one")
        XCTAssertEqual(b.stores[order[4]]?.logicalString(), "text 5")
        XCTAssertTrue(b.session.buffers[order[0]]!.dirty)
    }

    func testRenamedUntitledKeepsItsNameThroughEditsAndRelaunch() async {
        let a = await launch()
        let id = a.session.selectedBufferID!
        type("first line", into: a)
        a.renameTab(id, to: "  Notes  ")
        type("\nmore", into: a)
        a.refreshUntitledTitle(id, store: a.stores[id]!)
        XCTAssertEqual(a.session.buffers[id]?.title, "Notes")
        await a.performFlush()

        let b = await launch()
        XCTAssertEqual(b.session.buffers[id]?.title, "Notes")
        b.renameTab(id, to: " ")                                 // blank goes back to the text's first line
        XCTAssertEqual(b.session.buffers[id]?.title, "first line")
        XCTAssertFalse(b.session.buffers[id]!.titleIsCustom)
    }

    func testDirtyFileSurvivesRelaunchAndDiskIsUntouched() async throws {
        let f = files.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: f)
        let mtime = try FileManager.default.attributesOfItem(atPath: f.path)[.modificationDate] as! Date

        let a = await launch()
        await a.openURLsAsync([f])
        let id = a.session.selectedBufferID!
        XCTAssertEqual(a.session.buffers[id]?.title, "config.json")
        XCTAssertFalse(a.session.buffers[id]!.dirty)             // a non-empty opened file is clean
        type("\n// edit", into: a)
        XCTAssertTrue(a.session.buffers[id]!.dirty)              // dirty on the keystroke
        await a.performFlush()

        let b = await launch()
        XCTAssertEqual(b.stores[id]?.logicalString(), "{}\n// edit")
        XCTAssertTrue(b.session.buffers[id]!.dirty)
        XCTAssertEqual(b.session.buffers[id]?.conflict, ConflictState.none)
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "{}")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: f.path)[.modificationDate] as! Date, mtime)
    }

    func testSameFileOpenedTwiceFocusesExistingTab() async throws {
        let f = files.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: f)
        let s = await launch()
        await s.openURLsAsync([f])
        await s.openURLsAsync([f])
        XCTAssertEqual(s.session.tabOrder.count, 2)   // Untitled + a.txt
    }

    func testInvalidUTF8IsRejectedWithoutBuffer() async throws {
        let f = files.appendingPathComponent("bin.dat")
        try Data([0xC3, 0x28, 0xFF]).write(to: f)
        let s = await launch()
        await s.openURLsAsync([f])
        XCTAssertEqual(s.session.tabOrder.count, 1)
        XCTAssertEqual(s.toast?.text, String(localized: "Could not open file"))
    }

    func testSaveWritesBytesPreservesCRLFAndClearsDirty() async throws {
        let f = files.appendingPathComponent("w.txt")
        try Data("a\r\nb\r\n".utf8).write(to: f)
        let s = await launch()
        await s.openURLsAsync([f])
        let id = s.session.selectedBufferID!
        XCTAssertEqual(s.session.buffers[id]?.lineEnding, .crlf)
        XCTAssertEqual(s.stores[id]?.logicalString(), "a\nb\n")
        type("c\n", into: s)
        let out = await s.performSave(id: id, url: f, overwrite: false, presenter: s.monitors[id])
        XCTAssertEqual(out, .saved)
        XCTAssertEqual(try Data(contentsOf: f), Data("a\r\nb\r\nc\r\n".utf8))
        XCTAssertFalse(s.session.buffers[id]!.dirty)
    }

    func testGBKFileOpensAndConvertsToUTF8OnlyWhenAsked() async throws {
        let f = files.appendingPathComponent("gbk.txt")
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GBK_95.rawValue)))
        let bytes = try XCTUnwrap("第一行\r\n第二行\r\n".data(using: gbk))
        try bytes.write(to: f)
        let s = await launch()
        await s.openURLsAsync([f])
        let id = s.session.selectedBufferID!
        XCTAssertEqual(s.session.buffers[id]?.encoding, .gb18030)
        XCTAssertEqual(s.stores[id]?.logicalString(), "第一行\n第二行\n")

        let saved = await s.saveWithAsync(id, encoding: .utf8, lineEnding: .lf)
        XCTAssertTrue(saved)
        XCTAssertEqual(try Data(contentsOf: f), Data("第一行\n第二行\n".utf8))
        XCTAssertEqual(s.status.encoding, .utf8)
        XCTAssertFalse(s.session.buffers[id]!.dirty)
    }

    func testReopenWithEncodingReadsTheSameBytesAnotherWay() async throws {
        let f = files.appendingPathComponent("ambiguous.txt")
        let text = "你好"
        try Data(text.utf8).write(to: f)
        let s = await launch()
        await s.openURLsAsync([f])
        let id = s.session.selectedBufferID!
        XCTAssertEqual(s.session.buffers[id]?.encoding, .utf8)

        await s.reopenAsync(id, with: .gb18030)
        XCTAssertEqual(s.session.buffers[id]?.encoding, .gb18030)
        XCTAssertNotEqual(s.stores[id]?.logicalString(), text)
        XCTAssertTrue(s.stores[id]!.changeMarkers.isEmpty)
        XCTAssertFalse(s.session.buffers[id]!.dirty)

        // The encoding survives a reload, even though the bytes are also valid UTF-8.
        await s.reloadFromDisk(id)
        XCTAssertEqual(s.session.buffers[id]?.encoding, .gb18030)

        await s.reopenAsync(id, with: .utf8)
        XCTAssertEqual(s.stores[id]?.logicalString(), text)
        XCTAssertEqual(try Data(contentsOf: f), Data(text.utf8))   // reopening never writes
    }

    func testIndentOverrideWinsOverDetection() async throws {
        let s = await launch()
        type("a\n  b\n    c\n", into: s)
        s.stores[s.session.selectedBufferID!]!.scheduleLineIndex(delay: .zero)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(s.activeIndentStyle, .spaces(2))
        s.setIndentOverride(.tabs)
        XCTAssertEqual(s.activeIndentStyle, .tabs)
        XCTAssertEqual(s.status.indent, .tabs)
        s.setIndentOverride(nil)
        XCTAssertEqual(s.activeIndentStyle, .spaces(2))
    }

    func testExecutableBitSurvivesSaveOrWarns() async throws {
        let f = files.appendingPathComponent("run.sh")
        try Data("#!/bin/sh\n".utf8).write(to: f)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        let s = await launch()
        await s.openURLsAsync([f])
        let id = s.session.selectedBufferID!
        type("echo hi\n", into: s)
        _ = await s.performSave(id: id, url: f, overwrite: false, presenter: s.monitors[id])
        let mode = (try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as! NSNumber).intValue
        XCTAssertNotEqual(mode & 0o111, 0)
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "#!/bin/sh\necho hi\n")
    }

    func testExternalChangeOnCleanBufferWaitsForUserToReload() async throws {
        let f = files.appendingPathComponent("c.txt")
        try Data("one".utf8).write(to: f)
        let s = await launch()
        await s.openURLsAsync([f])
        let id = s.session.selectedBufferID!
        try Data("two".utf8).write(to: f)
        let ack = s.session.buffers[id]?.diskContentHash
        await s.handleExternalChange(id)
        XCTAssertEqual(s.stores[id]?.logicalString(), "one")
        XCTAssertEqual(s.session.buffers[id]?.diskContentHash, ack)
        XCTAssertEqual(s.session.buffers[id]?.conflict, .external)
        XCTAssertNotNil(s.banner)
        await s.reloadFromDisk(id)
        XCTAssertEqual(s.stores[id]?.logicalString(), "two")
        XCTAssertFalse(s.session.buffers[id]!.dirty)
        XCTAssertEqual(s.session.buffers[id]?.conflict, ConflictState.none)
    }

    func testKeepVersionStaysDismissedUntilAnotherDiskChange() async throws {
        let f = files.appendingPathComponent("keep.txt")
        try Data("base".utf8).write(to: f)
        let s = await launch()
        await s.openURLsAsync([f])
        let id = s.session.selectedBufferID!
        // Check focus fallback without relying on the file presenter callback.
        s.monitors[id]?.unregister()
        type(" local", into: s)
        let store = s.stores[id]!
        // Direct textStorage edits in this fixture bypass NSTextView's undo registration.
        store.undoManager.registerUndo(withTarget: store) { target in
            target.textStorage.replaceCharacters(in: NSRange(location: 4, length: 6), with: "")
        }
        let generation = store.generation
        let ack = s.session.buffers[id]?.diskContentHash
        try Data("external".utf8).write(to: f, options: .atomic)
        await s.checkSelectedFileForExternalChanges()
        XCTAssertNotNil(s.banner)
        s.applyConflictAction(.keepMyVersion)
        await s.checkSelectedFileForExternalChanges()
        XCTAssertNil(s.banner)
        try Data("external again".utf8).write(to: f, options: .atomic)
        await s.checkSelectedFileForExternalChanges()
        XCTAssertNotNil(s.banner)
        XCTAssertEqual(store.logicalString(), "base local")
        XCTAssertEqual(store.generation, generation)
        XCTAssertTrue(store.undoManager.canUndo)
        XCTAssertEqual(s.session.buffers[id]?.diskContentHash, ack)
    }

    func testKeptBannerStaysHiddenAcrossTabSwitches() async throws {
        let f = files.appendingPathComponent("kept.txt")
        try Data("base".utf8).write(to: f)
        let s = await launch()
        await s.openURLsAsync([f])
        let id = s.session.selectedBufferID!
        s.monitors[id]?.unregister()
        try Data("external".utf8).write(to: f, options: .atomic)
        await s.checkSelectedFileForExternalChanges()
        s.applyConflictAction(.keepMyVersion)
        XCTAssertNil(s.banner)
        s.newTab()
        s.selectTab(id)
        await s.checkSelectedFileForExternalChanges()
        XCTAssertNil(s.banner)
        XCTAssertEqual(s.session.buffers[id]?.conflict, .external)
    }

    /// A conflict whose bytes were never read (restored, or from a refused save) keeps the first bytes read.
    func testKeepingAnUnreadConflictAdoptsTheNextRead() async throws {
        let f = files.appendingPathComponent("unread.txt")
        try Data("base".utf8).write(to: f)
        let s = await launch()
        await s.openURLsAsync([f])
        let id = s.session.selectedBufferID!
        s.monitors[id]?.unregister()
        try Data("external".utf8).write(to: f, options: .atomic)
        s.session.buffers[id]?.conflict = .external
        s.applyConflictAction(.keepMyVersion)
        await s.checkSelectedFileForExternalChanges()
        XCTAssertNil(s.banner)
        try Data("external again".utf8).write(to: f, options: .atomic)
        await s.checkSelectedFileForExternalChanges()
        XCTAssertNotNil(s.banner)
    }

    func testSwitchingTabsChecksForUncoordinatedDiskChanges() async throws {
        let f = files.appendingPathComponent("switch.txt")
        try Data("before".utf8).write(to: f)
        let s = await launch()
        await s.openURLsAsync([f])
        let id = s.session.selectedBufferID!
        s.monitors[id]?.unregister()
        s.newTab()
        try Data("after".utf8).write(to: f, options: .atomic)
        s.selectTab(id)
        for _ in 0..<40 where s.session.buffers[id]?.conflict != .external {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(s.session.buffers[id]?.conflict, .external)
        XCTAssertEqual(s.stores[id]?.logicalString(), "before")
        XCTAssertNotNil(s.banner)
    }

    func testUnchangedDiskDoesNotPrompt() async throws {
        let f = files.appendingPathComponent("unchanged.txt")
        try Data("same".utf8).write(to: f)
        let s = await launch()
        await s.openURLsAsync([f])
        await s.checkSelectedFileForExternalChanges()
        XCTAssertNil(s.banner)
        XCTAssertEqual(s.selectedBuffer?.conflict, ConflictState.none)
    }

    func testExternalReloadMarksChangedLinesUntilCleared() async throws {
        let f = files.appendingPathComponent("m.txt")
        try Data("a\nb\nc\n".utf8).write(to: f)
        let s = await launch()
        await s.openURLsAsync([f])
        let id = s.session.selectedBufferID!
        try Data("a\nB\nc\nd\n".utf8).write(to: f)
        await s.handleExternalChange(id)
        await s.reloadFromDisk(id)
        let store = s.stores[id]!
        XCTAssertEqual(store.changeMarkers, [
            ChangeMarker(kind: .modified, range: NSRange(location: 2, length: 2)),
            ChangeMarker(kind: .added, range: NSRange(location: 6, length: 2)),
        ])
        XCTAssertFalse(store.undoManager.canUndo)

        type("x", into: s)                       // typing after the runs leaves them alone
        XCTAssertEqual(store.changeMarkers.count, 2)
        s.clearChangeMarkers()
        XCTAssertEqual(store.changeMarkers, [])
    }

    func testExternalChangeOnDirtyBufferNeverOverwritesEvenAcrossRelaunch() async throws {
        let f = files.appendingPathComponent("d.txt")
        try Data("base".utf8).write(to: f)
        let a = await launch()
        await a.openURLsAsync([f])
        let id = a.session.selectedBufferID!
        let ack = a.session.buffers[id]!.diskContentHash
        type("+mine", into: a)
        try Data("H2".utf8).write(to: f)                         // another program edits the file
        await a.handleExternalChange(id)
        XCTAssertEqual(a.session.buffers[id]?.conflict, .external)
        XCTAssertEqual(a.stores[id]?.logicalString(), "base+mine")  // text untouched
        XCTAssertEqual(a.session.buffers[id]?.diskContentHash, ack) // baseline not advanced
        await a.performFlush()

        // Quit and relaunch: the warning survives and the stored hash is still the old acknowledgement.
        let b = await launch()
        XCTAssertEqual(b.session.buffers[id]?.conflict, .external)
        XCTAssertEqual(b.session.buffers[id]?.diskContentHash, ack)
        XCTAssertEqual(b.stores[id]?.logicalString(), "base+mine")

        // Save without confirmation must refuse and leave H2 on disk (this is what Cancel relies on).
        let out = await b.performSave(id: id, url: f, overwrite: false, presenter: nil)
        XCTAssertEqual(out, .conflict)
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "H2")
        XCTAssertEqual(b.session.buffers[id]?.diskContentHash, ack)
    }

    func testCleanBufferWhoseFileChangedWhileClosedPromptsOnLaunch() async throws {
        let f = files.appendingPathComponent("e.txt")
        try Data("old".utf8).write(to: f)
        let a = await launch()
        await a.openURLsAsync([f])
        let id = a.session.selectedBufferID!
        await a.performFlush()
        try Data("new".utf8).write(to: f)
        let b = await launch()
        XCTAssertEqual(b.stores[id]?.logicalString(), "old")
        XCTAssertEqual(b.session.buffers[id]?.conflict, .external)
        XCTAssertNotNil(b.banner)
    }

    func testCleanFileTabSurvivesRelaunch() async throws {
        // Snapshot invariant: a clean file-backed tab must not vanish for lack of a snapshot.
        let f = files.appendingPathComponent("README.md")
        try Data("# hi".utf8).write(to: f)
        let a = await launch()
        await a.openURLsAsync([f])
        let id = a.session.selectedBufferID!
        await a.performFlush()
        let b = await launch()
        XCTAssertNotNil(b.session.buffers[id])
        XCTAssertEqual(b.session.buffers[id]?.language, .markdown)
    }

    func testDeletedFileOnLaunchBecomesMissingAndKeepsText() async throws {
        let f = files.appendingPathComponent("gone.txt")
        try Data("keep".utf8).write(to: f)
        let a = await launch()
        await a.openURLsAsync([f])
        let id = a.session.selectedBufferID!
        type("!", into: a)
        await a.performFlush()
        try FileManager.default.removeItem(at: f)
        let b = await launch()
        XCTAssertEqual(b.session.buffers[id]?.conflict, .missing)
        XCTAssertEqual(b.stores[id]?.logicalString(), "keep!")
    }

    func testDiscardedTabDoesNotComeBack() async {
        let a = await launch()
        type("secret", into: a)
        let id = a.session.selectedBufferID!
        await a.performFlush()
        a.removeBuffer(id)                      // Discard
        try? await Task.sleep(for: .milliseconds(300))
        let snap = root.appendingPathComponent("Buffers/\(id.uuidString).snapshot")
        XCTAssertFalse(FileManager.default.fileExists(atPath: snap.path))
        let b = await launch()
        XCTAssertNil(b.session.buffers[id])
        XCTAssertFalse(b.stores.values.contains { $0.logicalString() == "secret" })
    }

    func testClosingLastTabCreatesFreshUntitled() async {
        let s = await launch()
        let id = s.session.selectedBufferID!
        s.removeBuffer(id)
        XCTAssertEqual(s.session.tabOrder.count, 1)
        XCTAssertNotEqual(s.session.tabOrder.first, id)
    }

    func testCorruptManifestStillRecoversSnapshots() async throws {
        let a = await launch()
        type("precious", into: a)
        let id = a.session.selectedBufferID!
        await a.performFlush()
        try Data("garbage".utf8).write(to: root.appendingPathComponent("Session/session.json"))
        let b = await launch()
        XCTAssertTrue(b.stores.values.contains { $0.logicalString() == "precious" })
        XCTAssertTrue(b.session.orderedBuffers.contains { $0.title.hasPrefix("Recovered") })
        _ = id
    }

    func testNothingWrittenBeforeGateOpens() async {
        let s = AppState(root: root, autoRestore: false)
        s.flushImmediately()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Session/session.json").path))
    }

    func testFindReplaceAllIsOneUndoGroup() async {
        let s = await launch()
        type("a b a b a", into: s)
        s.host.activate(s.activeStore!, settings: s.settings)
        s.find.query = "a"
        s.find.replacement = "xx"
        s.replaceAll()
        XCTAssertEqual(s.activeStore?.logicalString(), "xx b xx b xx")
        s.activeStore?.undoManager.undo()
        XCTAssertEqual(s.activeStore?.logicalString(), "a b a b a")
    }

    /// Typing a query counts and highlights every match and selects the first one from where find opened;
    /// stepping moves "current/total", and edits are counted again.
    func testFindCountsAndStepsThroughMatches() async throws {
        let s = await launch()
        type("abc ABC abc", into: s)
        s.host.activate(s.activeStore!, settings: s.settings)
        s.host.textView.setSelectedRange(NSRange(location: 1, length: 0))
        s.showFind(replace: false)
        s.find.query = "abc"
        s.findQueryChanged()
        try await waitUntil { s.find.matchCount == 3 }
        XCTAssertEqual(s.host.textView.selectedRange(), NSRange(location: 4, length: 3))
        XCTAssertEqual(s.find.currentMatch, 2)

        s.findNext()
        XCTAssertEqual(s.find.currentMatch, 3)
        s.findNext()
        XCTAssertEqual(s.find.currentMatch, 1)   // wraps
        s.findPrevious()
        XCTAssertEqual(s.find.currentMatch, 3)

        s.find.caseSensitive = true
        s.findQueryChanged()
        try await waitUntil { s.find.matchCount == 2 }

        type(" abc", into: s)
        try await waitUntil { s.find.matchCount == 3 }

        s.find.query = "zzz"
        s.findQueryChanged()
        try await waitUntil { s.find.matchCount == 0 }
        XCTAssertNil(s.find.currentMatch)

        s.hideFind()
        XCTAssertNil(s.find.matchCount)
    }

    /// Save trims trailing whitespace and adds the final newline, in the buffer (one undo step) and on disk.
    func testSaveCleansUpTrailingWhitespaceAndFinalNewline() async throws {
        let url = files.appendingPathComponent("clean.swift")
        try "let a = 1\n".write(to: url, atomically: true, encoding: .utf8)
        let s = await launch()
        await s.openURLsAsync([url])
        s.host.activate(s.activeStore!, settings: s.settings)
        s.host.textView.insertText("let b = 2   \nlet c = 3", replacementRange: NSRange(location: 10, length: 0))
        closeEventUndoGroup(s)
        let saved = await s.saveFlow(s.session.selectedBufferID!)
        XCTAssertTrue(saved)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "let a = 1\nlet b = 2\nlet c = 3\n")
        XCTAssertEqual(s.activeStore?.logicalString(), "let a = 1\nlet b = 2\nlet c = 3\n")
        s.activeStore?.undoManager.undo()
        XCTAssertEqual(s.activeStore?.logicalString(), "let a = 1\nlet b = 2   \nlet c = 3")
    }

    func testGoToLineAndLineCommands() async throws {
        let s = await launch()
        type("one\ntwo\nthree", into: s)
        s.host.activate(s.activeStore!, settings: s.settings)
        XCTAssertTrue(s.goToLine("2:3"))
        XCTAssertEqual(s.host.textView.selectedRange(), NSRange(location: 6, length: 0))
        XCTAssertTrue(s.goToLine("99"))
        XCTAssertEqual(s.host.textView.selectedRange(), NSRange(location: 8, length: 0))
        XCTAssertFalse(s.goToLine("x"))

        XCTAssertTrue(s.goToLine("2"))
        s.runLineCommand(.moveUp)
        XCTAssertEqual(s.activeStore?.logicalString(), "two\none\nthree")
        s.runLineCommand(.duplicate)
        XCTAssertEqual(s.activeStore?.logicalString(), "two\ntwo\none\nthree")
        s.runLineCommand(.delete)
        s.runLineCommand(.toggleComment)   // plain text: a toast, no edit
        XCTAssertEqual(s.activeStore?.logicalString(), "two\none\nthree")
        s.setLanguage(.python)
        closeEventUndoGroup(s)
        s.runLineCommand(.toggleComment)
        XCTAssertEqual(s.activeStore?.logicalString(), "two\n# one\nthree")
        s.activeStore?.undoManager.undo()
        XCTAssertEqual(s.activeStore?.logicalString(), "two\none\nthree")
    }

    /// Ends the undo group AppKit opened for this "event"; separate key presses would each get their own.
    private func closeEventUndoGroup(_ s: AppState) {
        guard let um = s.activeStore?.undoManager else { return }
        while um.groupingLevel > 0 { um.endUndoGrouping() }
    }

    private func waitUntil(_ cond: () -> Bool) async throws {
        for _ in 0..<200 where !cond() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(cond())
    }

    func testJSONFormatThroughAppState() async throws {
        let s = await launch()
        type("{\"a\":1}", into: s)
        s.host.activate(s.activeStore!, settings: s.settings)
        s.formatJSON()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(s.activeStore?.logicalString(), "{\n  \"a\": 1\n}")
        type("{", into: s)
        s.formatJSON()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(s.toast?.isError, true)
    }

    func testTextToolReplacesTrimmedSelectionAsOneUndoGroup() async throws {
        let s = await launch()
        type("token: eyJhIjoxfQ \nnext", into: s)
        s.host.activate(s.activeStore!, settings: s.settings)
        s.host.textView.setSelectedRange(NSRange(location: 6, length: 12))   // " eyJhIjoxfQ "
        s.run(.base64Decode)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(s.activeStore?.logicalString(), "token: {\"a\":1} \nnext")
        XCTAssertEqual(s.host.textView.selectedRange(), NSRange(location: 7, length: 7))   // output selected for chaining
        s.run(.base64Decode)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(s.toast?.isError, true)
        XCTAssertEqual(s.activeStore?.logicalString(), "token: {\"a\":1} \nnext")
        s.activeStore?.undoManager.undo()
        XCTAssertEqual(s.activeStore?.logicalString(), "token: eyJhIjoxfQ \nnext")
    }

    func testSuccessfulFlushClearsAnEarlierQuitRefusal() async {
        let s = await launch()
        s.terminationRefused = true      // an earlier Quit timed out or failed
        type("x", into: s)
        await s.performFlush()
        XCTAssertFalse(s.terminationRefused)   // the next Quit flushes instead of offering a lossy exit
    }

    func testPastedCRLFSavesAsCRLFWithoutDoubledBreaks() async throws {
        let f = files.appendingPathComponent("win.txt")
        try Data("a\r\nb\r\n".utf8).write(to: f)
        let s = await launch()
        await s.openURLsAsync([f])
        let id = s.session.selectedBufferID!
        s.host.activate(s.stores[id]!, settings: s.settings)
        s.host.textView.setSelectedRange(NSRange(location: s.stores[id]!.length, length: 0))
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("c\r\nd\r\n", forType: .string)
        XCTAssertTrue(s.host.textView.readSelection(from: pb, type: .string))
        let outcome = await s.performSave(id: id, url: f, overwrite: false, presenter: s.monitors[id])
        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(try Data(contentsOf: f), Data("a\r\nb\r\nc\r\nd\r\n".utf8))
    }

    // MARK: Paste suggestions

    /// What `EditorTextView.paste(_:)` does, on a private pasteboard so the user's clipboard is untouched.
    private func paste(_ text: String, into s: AppState) {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString(text, forType: .string)
        s.beginPasteRecognition()
        XCTAssertTrue(s.host.textView.readSelection(from: pb, type: .string))
        s.endPasteRecognition()
    }

    func testPasteIntoEmptyTabOffersJSONAndFormatsTheWholeTab() async throws {
        let s = await launch()
        s.host.activate(s.activeStore!, settings: s.settings)
        paste(#"{"a":1}"#, into: s)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(s.selectedBuffer?.pasteSuggestion, PasteSuggestion(language: .json, canFormatJSON: true))
        s.host.textView.setSelectedRange(NSRange(location: 1, length: 2))   // a selection does not narrow the format
        s.formatPastedJSON()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(s.activeStore?.logicalString(), "{\n  \"a\": 1\n}")
        XCTAssertEqual(s.selectedBuffer?.language, .json)
        XCTAssertNil(s.selectedBuffer?.pasteSuggestion)
    }

    /// Language is offered only for a paste that leaves the tab holding just the pasted text, whatever the tab's
    /// language and even after a language suggestion was dismissed; decodes for any one-line paste.
    func testPasteIsRecognizedOnlyWhenItFillsTheTab() async throws {
        let s = await launch()
        s.host.activate(s.activeStore!, settings: s.settings)
        paste("const f = (x) => x;\nconsole.log(f(1));\n", into: s)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(s.selectedBuffer?.pasteSuggestion?.language, .javascript)
        s.applyPastedLanguage()
        XCTAssertEqual(s.selectedBuffer?.language, .javascript)
        XCTAssertTrue(s.selectedBuffer!.languageDetectionSuppressed)

        s.host.textView.setSelectedRange(NSRange(location: s.activeStore!.length, length: 0))
        paste("{\"c\":3}\n", into: s)                                      // appended: no language offer
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(s.selectedBuffer?.pasteSuggestion)

        s.host.textView.selectAll(nil)
        paste("SGVsbG8=", into: s)                                          // over everything: recognized
        try await Task.sleep(for: .milliseconds(300))
        let candidate = try XCTUnwrap(s.selectedBuffer?.pasteSuggestion?.candidates.first)
        XCTAssertEqual(candidate.kind, .base64)
        s.replaceWithDecodedPaste(candidate)
        XCTAssertEqual(s.activeStore?.logicalString(), "Hello")
        XCTAssertNil(s.selectedBuffer?.pasteSuggestion)

        s.host.textView.selectAll(nil)
        s.host.textView.delete(nil)
        paste(#"{"b":2}"#, into: s)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(s.selectedBuffer?.pasteSuggestion?.language, .json)
        type(" ", into: s)
        XCTAssertNil(s.selectedBuffer?.pasteSuggestion)                    // the next edit hides it
    }

    /// A one-line paste among other text is offered its decodes only; Replace swaps just the pasted text and
    /// leaves the tab's language alone.
    func testPasteAmongOtherTextOffersDecodesOnly() async throws {
        let s = await launch()
        type("let a = \n", into: s)
        s.host.activate(s.activeStore!, settings: s.settings)
        s.host.textView.setSelectedRange(NSRange(location: 8, length: 0))
        paste("eyJiIjoyfQ==", into: s)
        try await Task.sleep(for: .milliseconds(300))
        let suggestion = try XCTUnwrap(s.selectedBuffer?.pasteSuggestion)
        XCTAssertNil(suggestion.language)
        XCTAssertFalse(suggestion.canFormatJSON)
        XCTAssertEqual(suggestion.decodeRange, NSRange(location: 8, length: 12))
        let candidate = try XCTUnwrap(suggestion.candidates.first)
        XCTAssertEqual(candidate.kind, .base64)
        XCTAssertTrue(candidate.isJSON)
        s.replaceWithDecodedPaste(candidate)
        XCTAssertEqual(s.activeStore?.logicalString(), "let a = {\n  \"b\": 2\n}\n")
        XCTAssertNotEqual(s.selectedBuffer?.language, .json)
        XCTAssertNil(s.selectedBuffer?.pasteSuggestion)

        s.host.textView.setSelectedRange(NSRange(location: 0, length: 0))
        paste("a\nSGVsbG8=", into: s)                                      // two lines: nothing to decode
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(s.selectedBuffer?.pasteSuggestion)
    }

    /// Any paste is checked for escape codes and invisible characters; Remove cleans only the pasted text.
    func testPasteWithEscapeCodesOffersCleanupOfThePastedText() async throws {
        let s = await launch()
        type("keep\u{200B}\n", into: s)
        s.host.activate(s.activeStore!, settings: s.settings)
        s.host.textView.setSelectedRange(NSRange(location: s.activeStore!.length, length: 0))
        paste("\u{1B}[31mred\u{1B}[0m\u{200B}", into: s)
        try await Task.sleep(for: .milliseconds(300))
        let cleanup = try XCTUnwrap(s.selectedBuffer?.pasteSuggestion?.cleanup)
        XCTAssertEqual(cleanup.report.ansiSequences, 2)
        XCTAssertEqual(cleanup.report.invisibleCount, 1)
        XCTAssertFalse(cleanup.fillsTab)
        s.cleanUpPaste()
        XCTAssertEqual(s.activeStore?.logicalString(), "keep\u{200B}\nred")
        XCTAssertNil(s.selectedBuffer?.pasteSuggestion)
    }

    /// A pasted curl command is offered with its summary, among other text too; nothing is sent until Send.
    func testPastedCurlIsOfferedNotSent() async throws {
        let s = await launch()
        type("notes\n", into: s)
        s.host.activate(s.activeStore!, settings: s.settings)
        s.host.textView.setSelectedRange(NSRange(location: s.activeStore!.length, length: 0))
        paste("curl -X POST https://x.test/v1/a \\\n  -H 'Authorization: Bearer t' \\\n  -d '{\"a\":1}'", into: s)
        try await Task.sleep(for: .milliseconds(300))
        let offer = try XCTUnwrap(s.selectedBuffer?.pasteSuggestion?.curl)
        XCTAssertEqual(offer.summary.method, "POST")
        XCTAssertEqual(offer.summary.host, "x.test")
        XCTAssertTrue(offer.summary.sendsCredentials)
        XCTAssertEqual(offer.summary.bodyKind, .json)
        XCTAssertNil(s.selectedBuffer?.curlRun)
        type(" ", into: s)
        XCTAssertNil(s.selectedBuffer?.pasteSuggestion)                    // the next edit hides it

        s.host.textView.setSelectedRange(NSRange(location: 0, length: 0))
        s.sendCurlAtCursor()
        XCTAssertEqual(s.toast?.text, String(localized: "No curl command at the cursor"))
        XCTAssertNil(s.selectedBuffer?.curlRun)

        var off = s.settings
        off.recognizeCurlCommands = false
        s.updateSettings(off)
        defer { var on = s.settings; on.recognizeCurlCommands = true; s.updateSettings(on) }
        s.host.textView.setSelectedRange(NSRange(location: s.activeStore!.length, length: 0))
        paste("\ncurl https://x.test", into: s)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(s.selectedBuffer?.pasteSuggestion?.curl)
    }

    /// Replace puts the response where the command was, keeping the text around it; a moved command is found
    /// by its text, and a deleted one is an error.
    func testReplaceCurlCommandWithResponse() async throws {
        let s = await launch()
        type("notes\ncurl https://x.test/a\nend", into: s)
        s.host.activate(s.activeStore!, settings: s.settings)
        let id = try XCTUnwrap(s.session.selectedBufferID)
        let ns = s.activeStore!.textStorage.mutableString
        let range = try XCTUnwrap(CurlCommand.commandRange(around: 8, in: ns))
        let source = try XCTUnwrap(AppState.curlSource(range, in: ns))
        XCTAssertEqual(source.text, "curl https://x.test/a")
        func finish() {
            let summary = CurlSummary(CurlCommand.parse(source.text)!)
            let result = CurlResult(status: 200, reason: "OK", elapsed: .zero, byteCount: 8, headers: [],
                                    body: .text(preview: "{\"a\": 1}", language: .json))
            s.curlSources[id] = source
            s.curlBodies[id] = "{\"a\": 1}"
            s.session.buffers[id]?.curlRun = .finished(summary, result)
        }

        finish()
        s.host.textView.setSelectedRange(NSRange(location: 0, length: 0))
        s.host.textView.insertText("> ", replacementRange: NSRange(location: 0, length: 0))
        s.replaceCurlCommandWithResponse()
        XCTAssertEqual(s.activeStore?.logicalString(), "> notes\n{\"a\": 1}\nend")
        XCTAssertNil(s.selectedBuffer?.curlRun)
        XCTAssertNotEqual(s.selectedBuffer?.language, .json)                 // not the whole tab

        finish()
        s.replaceCurlCommandWithResponse()
        XCTAssertEqual(s.toast?.text, String(localized: "The curl command is no longer in the tab"))
        XCTAssertNotNil(s.selectedBuffer?.curlRun)
    }

    /// After a paste that filled the tab, removing the escape codes makes the usual offer for the clean text.
    func testCleanupBeforeTheLanguageOffer() async throws {
        let s = await launch()
        s.host.activate(s.activeStore!, settings: s.settings)
        paste("\u{1B}[32m{\"a\":1}\u{1B}[0m", into: s)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(s.selectedBuffer?.pasteSuggestion?.cleanup?.fillsTab, true)
        XCTAssertNil(s.selectedBuffer?.pasteSuggestion?.language)
        s.cleanUpPaste()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(s.activeStore?.logicalString(), #"{"a":1}"#)
        XCTAssertEqual(s.selectedBuffer?.pasteSuggestion, PasteSuggestion(language: .json, canFormatJSON: true))
    }

    func testLineToolTakesWholeSelectedLines() async throws {
        let s = await launch()
        type("  c\n  a\n  b\nz", into: s)
        s.host.activate(s.activeStore!, settings: s.settings)
        s.host.textView.setSelectedRange(NSRange(location: 3, length: 7))   // from the end of "  c" into "  b"
        s.run(.sortLinesAscending)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(s.activeStore?.logicalString(), "  a\n  b\n  c\nz")
        XCTAssertEqual(s.host.textView.selectedRange(), NSRange(location: 0, length: 12))
    }

    /// Every tool says what it did, including that it found nothing, and whether it ran on a selection.
    func testToolsReportWhatTheyDid() async throws {
        let s = await launch()
        type("a\u{200B}b\na\u{200B}b\n", into: s)
        s.host.activate(s.activeStore!, settings: s.settings)
        s.run(.removeInvisibleCharacters)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(s.activeStore?.logicalString(), "ab\nab\n")
        XCTAssertEqual(s.toast?.text, AppState.message(for: .removedInvisible(2, [.init(value: 0x200B, count: 2)])))
        s.run(.removeInvisibleCharacters)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(s.toast?.text, AppState.message(for: .removedInvisible(0, [])))
        s.host.textView.setSelectedRange(NSRange(location: 0, length: 2))
        s.run(.removeDuplicateLines)
        try await Task.sleep(for: .milliseconds(300))
        let message = AppState.message(for: .removedDuplicates(0))                 // only the first line was taken
        XCTAssertEqual(s.toast?.text, String(localized: "\(message) (in selection)"))
        XCTAssertEqual(s.toast?.isError, false)
    }

    /// Opening the palette counts what the tools would find in the text they would run on.
    func testPaletteShowsWhatToolsWouldFind() async throws {
        let s = await launch()
        type("x\u{200B}\nx\u{200B}\n", into: s)
        s.host.activate(s.activeStore!, settings: s.settings)
        s.togglePalette()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(s.paletteOnSelection)
        XCTAssertEqual(s.paletteInsights?.counts[.removeInvisibleCharacters], 2)
        XCTAssertEqual(s.paletteInsights?.counts[.removeDuplicateLines], 1)
        XCTAssertEqual(s.paletteSections.first?.commands.map(\.id), ["removeInvisibleCharacters"])
        XCTAssertEqual(s.paletteCommands.first { $0.id == "removeBlankLines" }?.count, 0)
        s.hidePalette()
        s.host.textView.setSelectedRange(NSRange(location: 0, length: 1))
        s.togglePalette()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(s.paletteOnSelection)
        XCTAssertEqual(s.paletteInsights?.counts[.removeInvisibleCharacters], 0)
        XCTAssertEqual(s.paletteInsights?.suggested, [])
    }

    func testSelectionStatsFollowTheSelection() async throws {
        let s = await launch()
        type("你好 world\nnext", into: s)
        s.host.activate(s.activeStore!, settings: s.settings)
        s.host.textView.setSelectedRange(NSRange(location: 0, length: 9))
        XCTAssertEqual(s.selectionStats, SelectionStats(characters: 9, words: 3, lines: 1, utf8Bytes: 13))
        s.host.textView.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertNil(s.selectionStats)
        let big = String(repeating: "word ", count: 10_000)                  // past the synchronous limit
        type("\n" + big, into: s)
        s.host.textView.selectAll(nil)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(s.selectionStats?.words, 10_000 + 4)
    }

    func testJSONButtonsFollowTheCaretAndOpenTheValue() async throws {
        let s = await launch()
        type(#"{"name": "Ada", "payload": "{\"x\":[1,2]}", "n": 3}"#, into: s)
        s.host.activate(s.activeStore!, settings: s.settings)
        s.host.textView.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertNil(s.jsonCaret)                                            // Plain Text offers nothing
        s.setLanguage(.json)
        XCTAssertEqual(s.jsonCaret, JSONCaretInfo(path: "name", hasKey: true, canOpen: true))
        s.host.textView.setSelectedRange(NSRange(location: 49, length: 0))  // on 3
        XCTAssertEqual(s.jsonCaret, JSONCaretInfo(path: "n", hasKey: true, canOpen: false))
        s.host.textView.setSelectedRange(NSRange(location: 15, length: 0))  // between members
        XCTAssertNil(s.jsonCaret)

        s.host.textView.setSelectedRange(NSRange(location: 20, length: 0))  // in "payload"
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        s.copyJSONValue(to: pb)
        XCTAssertEqual(pb.string(forType: .string), #"{"x":[1,2]}"#)
        s.copyJSONKey(to: pb)
        XCTAssertEqual(pb.string(forType: .string), "payload")
        let source = s.session.selectedBufferID
        s.openJSONValue()
        for _ in 0..<40 where s.session.selectedBufferID == source { try await Task.sleep(for: .milliseconds(25)) }
        let opened = try XCTUnwrap(s.selectedBuffer)
        XCTAssertNotEqual(opened.id, source)
        XCTAssertEqual(opened.title, "payload")
        XCTAssertEqual(opened.language, .json)
        XCTAssertEqual(s.activeStore?.textStorage.string, "{\n  \"x\": [\n    1,\n    2\n  ]\n}")
    }

    func testJSONValueButtons() async throws {
        let s = await launch()
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        let doc = """
        {"next": "https://x.test/p?page=2&tag=a", "at": 1700000000, "b": "aGVsbG8gd29ybGQgZnJvbSBqc29u", \
        "icon": "data:image/png;base64,\(png)", "c": "#3366ff"}
        """
        type(doc, into: s)
        s.host.activate(s.activeStore!, settings: s.settings)
        s.setLanguage(.json)
        let ns = doc as NSString
        func caret(at needle: String) { s.host.textView.setSelectedRange(NSRange(location: ns.range(of: needle).location + 1, length: 0)) }

        caret(at: "https://")
        let link = try XCTUnwrap(s.jsonCaret?.value)
        XCTAssertEqual(link.link?.host(), "x.test")
        XCTAssertTrue(link.linkHasQuery)
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        s.copyJSONPath(to: pb)
        XCTAssertEqual(pb.string(forType: .string), "next")

        caret(at: "1700000000")
        XCTAssertEqual(s.jsonCaret?.value.date, Date(timeIntervalSince1970: 1_700_000_000))
        caret(at: "#3366ff")
        XCTAssertNotNil(s.jsonCaret?.value.color)

        caret(at: "aGVs")
        XCTAssertEqual(s.jsonCaret?.value.decodes, [.base64])
        s.decodeJSONValue()
        guard case .decodes(let candidates) = s.jsonValueCard?.content else { return XCTFail("no decode card") }
        XCTAssertEqual(candidates.first?.decoded, "hello world from json")
        caret(at: "1700000000")                                              // leaving the member hides it
        XCTAssertNil(s.jsonValueCard)

        caret(at: "data:image")
        XCTAssertEqual(s.jsonCaret?.value.image, .inline)
        s.previewJSONImage()
        for _ in 0..<40 where s.jsonValueCard == nil { try await Task.sleep(for: .milliseconds(25)) }
        guard case .image(let preview) = s.jsonValueCard?.content else { return XCTFail("no picture") }
        XCTAssertEqual(preview.pixelSize, CGSize(width: 1, height: 1))
        XCTAssertEqual(preview.suggestedName, "icon.png")
        XCTAssertTrue(s.dismissJSONValueCardFromEscape())
        XCTAssertNil(s.jsonValueCard)

        let source = s.session.selectedBufferID
        caret(at: "https://")
        s.openJSONQuery()
        let opened = try XCTUnwrap(s.selectedBuffer)
        XCTAssertNotEqual(opened.id, source)
        XCTAssertEqual(opened.title, "next query")
        XCTAssertEqual(opened.language, .json)
        XCTAssertEqual(s.activeStore?.textStorage.string, "{\n  \"page\": \"2\",\n  \"tag\": \"a\"\n}")
    }

    func testJSONPictureIconPreviewsItsValue() async throws {
        let s = await launch()
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        type("{\n  \"name\": \"Ada\",\n  \"icon\": \"data:image/png;base64,\(png)\"\n}", into: s)
        s.host.activate(s.activeStore!, settings: s.settings)
        s.host.textView.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertEqual(s.visibleJSONImages, [])                              // Plain Text has none
        s.setLanguage(.json)
        let image = try XCTUnwrap(s.visibleJSONImages.first)
        XCTAssertEqual(image.source, .inline)

        s.previewJSONImage(at: image.valueRange)
        XCTAssertEqual(s.host.textView.selectedRange(), NSRange(location: image.valueRange.location + 1, length: 0))
        XCTAssertEqual(s.jsonCaret?.path, "icon")
        for _ in 0..<40 where s.jsonValueCard == nil { try await Task.sleep(for: .milliseconds(25)) }
        guard case .image(let preview) = s.jsonValueCard?.content else { return XCTFail("no picture") }
        XCTAssertEqual(preview.pixelSize, CGSize(width: 1, height: 1))

        // An edit moves the value: the icons follow the new text, never the old ranges.
        s.host.textView.setSelectedRange(NSRange(location: 1, length: 0))
        s.host.textView.insertText("\n", replacementRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(s.visibleJSONImages.first?.valueRange.location, image.valueRange.location + 1)
    }

    func testBlankOutsideRange() {
        let text = " \n abc \n" as NSString
        XCTAssertTrue(AppState.isBlank(text, outside: NSRange(location: 3, length: 3)))
        XCTAssertTrue(AppState.isBlank(text, outside: NSRange(location: 0, length: text.length)))
        XCTAssertFalse(AppState.isBlank(text, outside: NSRange(location: 4, length: 2)))
        XCTAssertTrue(AppState.isBlank("" as NSString, outside: NSRange(location: 0, length: 0)))
    }

    // MARK: Tab context menu

    func testCloseTabsAroundATab() async throws {
        let s = await launch()
        for _ in 0..<4 { s.newTab() }
        let ids = s.session.tabOrder                                        // five clean Untitled tabs
        XCTAssertEqual(s.tabsToClose(.left, around: ids[2]), [ids[0], ids[1]])
        XCTAssertEqual(s.tabsToClose(.right, around: ids[2]), [ids[3], ids[4]])
        XCTAssertEqual(s.tabsToClose(.others, around: ids[2]), [ids[0], ids[1], ids[3], ids[4]])
        XCTAssertEqual(s.tabsToClose(.left, around: ids[0]), [])
        XCTAssertEqual(s.tabsToClose(.right, around: ids[4]), [])

        s.closeTabs(.right, around: ids[2])                                 // the selected last tab goes too
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(s.session.tabOrder, Array(ids[0...2]))
        XCTAssertEqual(s.session.selectedBufferID, ids[2])

        s.closeTabs(.others, around: ids[1])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(s.session.tabOrder, [ids[1]])
        XCTAssertEqual(s.session.selectedBufferID, ids[1])

        s.closeTabs(.all, around: ids[1])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(s.session.tabOrder.count, 1)                         // a fresh Untitled, as after the last close
        XCTAssertNotEqual(s.session.tabOrder.first, ids[1])
    }

    func testNextPreviousAndNumberedTabsWrapAndClamp() async {
        let s = await launch()
        for _ in 0..<3 { s.newTab() }
        let ids = s.session.tabOrder                                        // four tabs, the last selected
        s.selectAdjacentTab(1)
        XCTAssertEqual(s.session.selectedBufferID, ids[0])                  // wraps forward
        s.selectAdjacentTab(-1)
        XCTAssertEqual(s.session.selectedBufferID, ids[3])                  // and back
        s.selectTab(number: 2)
        XCTAssertEqual(s.session.selectedBufferID, ids[1])
        s.selectTab(number: 7)                                              // no seventh tab: nothing changes
        XCTAssertEqual(s.session.selectedBufferID, ids[1])
        s.selectTab(number: 9)                                              // always the last
        XCTAssertEqual(s.session.selectedBufferID, ids[3])
    }

    /// `n` snapshots with no manifest: the next launch adopts each one as a Recovered tab.
    private func writeOrphanSnapshots(_ n: Int) throws {
        let dir = root.appendingPathComponent("Buffers")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<n { try Data("tab \(i)".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).snapshot")) }
    }

    func testTabLimitBlocksNewTabs() async throws {
        try writeOrphanSnapshots(EditorSession.maxTabs)
        let s = await launch()
        let full = s.session.tabOrder
        XCTAssertEqual(full.count, EditorSession.maxTabs)
        XCTAssertFalse(s.hasRoomForTab)
        XCTAssertFalse(s.newTab())
        XCTAssertEqual(s.session.tabOrder, full)
        XCTAssertEqual(s.toast?.text, AppState.tabLimitMessage)

        // A tool that opens its result in a new tab does not drop it into the current one.
        s.dismissToast()
        let before = s.activeStore?.logicalString()
        XCTAssertFalse(s.openTranslationTab("result"))
        XCTAssertEqual(s.activeStore?.logicalString(), before)
        XCTAssertEqual(s.toast?.text, AppState.tabLimitMessage)

        // Opening files fills the room that is left and says how many were not opened.
        s.removeBuffer(full[0])
        s.removeBuffer(full[1])
        let urls = try (0..<3).map { i -> URL in
            let f = files.appendingPathComponent("f\(i).txt")
            try Data("\(i)".utf8).write(to: f)
            return f
        }
        await s.openURLsAsync(urls)
        XCTAssertEqual(s.session.tabOrder.count, EditorSession.maxTabs)
        XCTAssertEqual(s.toast?.text, String(localized: "Opened \(2) of \(3) files. Tabs are limited to \(EditorSession.maxTabs)."))
        await s.performFlush()
    }

    /// Restore never drops a buffer to stay under the limit; the limit only stops new tabs.
    func testRestoreIsNotCappedByTheTabLimit() async throws {
        try writeOrphanSnapshots(EditorSession.maxTabs + 1)
        let s = await launch()
        XCTAssertEqual(s.session.tabOrder.count, EditorSession.maxTabs + 1)
        XCTAssertFalse(s.newTab())
        await s.performFlush()
    }

    // MARK: Window size

    func testWindowSizeIsRememberedAndFitsTheScreen() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TinyEditTests-\(UUID().uuidString)"))
        XCTAssertEqual(WindowSize.load(from: defaults, visible: nil), WindowSize.standard)
        WindowSize.save(CGSize(width: 1200.4, height: 800), to: defaults)
        XCTAssertEqual(WindowSize.load(from: defaults, visible: CGSize(width: 1440, height: 875)), CGSize(width: 1200, height: 800))
        XCTAssertEqual(WindowSize.load(from: defaults, visible: CGSize(width: 1024, height: 700)), CGSize(width: 1024, height: 700))
        WindowSize.save(CGSize(width: 100, height: 100), to: defaults)
        XCTAssertEqual(WindowSize.load(from: defaults, visible: nil), WindowSize.minimum)
        defaults.set("garbage", forKey: WindowSize.storageKey)
        XCTAssertEqual(WindowSize.load(from: defaults, visible: nil), WindowSize.standard)
    }
}

/// Typing latency on the main thread: the keystroke path must stay O(1) on a large document.
@MainActor
final class TypingLatencyTests: XCTestCase {
    func testKeystrokePathIsCheapOnA3MBDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TL-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let s = AppState(root: root, autoRestore: false)
        await s.restore()
        let store = s.activeStore!
        let line = "let value = \"some text here\" // 0123456789\n"
        store.replaceLogicalText(String(repeating: line, count: 70_000), recordUndo: false, settings: s.settings)   // ~3 MB
        s.host.activate(store, settings: s.settings)
        s.setLanguage(.python)
        try await Task.sleep(for: .milliseconds(100))

        let n = 200
        let start = ContinuousClock.now
        for i in 0..<n {
            s.host.textView.insertText("x", replacementRange: NSRange(location: 1000 + i, length: 0))
        }
        let perKey = (ContinuousClock.now - start) / n
        print("per-keystroke main-thread cost on 3 MB doc: \(perKey)")
        XCTAssertLessThan(perKey, .milliseconds(8))
    }
}
