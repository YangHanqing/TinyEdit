import SwiftUI

struct AppCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // ⌘N does the same through AppDelegate, without a second menu item.
            Button("New Tab") { appState.newTabInWindow() }
                .keyboardShortcut(AppShortcut.newTab)
            Button("Open…") { appState.beginOpenPanel() }
                .keyboardShortcut(AppShortcut.open)
            Menu("Open Recent") {
                ForEach(appState.recentURLs, id: \.self) { url in
                    Button(url.lastPathComponent) { appState.openURLs([url]) }
                }
                Divider()
                Button("Clear Menu") { NSDocumentController.shared.clearRecentDocuments(nil) }
            }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { appState.closeSelectedTab() }
                .keyboardShortcut(AppShortcut.closeTab)
            Button("Close Window") { appState.hideWindow(NSApp.keyWindow) }
                .keyboardShortcut(AppShortcut.closeWindow)
            Button("Reopen Closed Tab") { appState.reopenClosedTab() }
                .keyboardShortcut(AppShortcut.reopenClosedTab)
            Divider()
            Button("Save") { appState.save() }
                .keyboardShortcut(AppShortcut.save)
            Button("Save As…") { appState.saveAs() }
                .keyboardShortcut(AppShortcut.saveAs)
        }
        CommandGroup(after: .windowSize) {
            Divider()
            // AppDelegate's key monitor handles the keys; the items show them and work from the menu.
            Button("Show Next Tab") { appState.selectAdjacentTab(1) }
                .keyboardShortcut(AppShortcut.nextTab)
            Button("Show Previous Tab") { appState.selectAdjacentTab(-1) }
                .keyboardShortcut(AppShortcut.previousTab)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find…") { appState.showFind(replace: false) }
                .keyboardShortcut(AppShortcut.find)
            Button("Find and Replace…") { appState.showFind(replace: true) }
                .keyboardShortcut(AppShortcut.findAndReplace)
            Button("Find Next") { appState.findNext() }
                .keyboardShortcut(AppShortcut.findNext)
            Button("Find Previous") { appState.findPrevious() }
                .keyboardShortcut(AppShortcut.findPrevious)
            Button("Go to Line…") { appState.showGoToLine() }
                .keyboardShortcut(AppShortcut.goToLine)
            Divider()
            Menu("Line") {
                Button("Duplicate Line") { appState.runLineCommand(.duplicate) }
                    .keyboardShortcut(AppShortcut.duplicateLine)
                Button("Move Line Up") { appState.runLineCommand(.moveUp) }
                    .keyboardShortcut(AppShortcut.moveLineUp)
                Button("Move Line Down") { appState.runLineCommand(.moveDown) }
                    .keyboardShortcut(AppShortcut.moveLineDown)
                Button("Delete Line") { appState.runLineCommand(.delete) }
                    .keyboardShortcut(AppShortcut.deleteLine)
                Button("Join Lines") { appState.runLineCommand(.join) }
                    .keyboardShortcut(AppShortcut.joinLines)
            }
            Button("Toggle Comment") { appState.runLineCommand(.toggleComment) }
                .keyboardShortcut(AppShortcut.toggleComment)
            Button("Toggle Task") { appState.runLineCommand(.toggleTask) }
                .keyboardShortcut(AppShortcut.toggleTask)
        }
        CommandGroup(after: .toolbar) {
            Button("Toggle Markdown Preview") { appState.togglePreview() }
                .keyboardShortcut(AppShortcut.markdownPreview)
            Button("Clear Change Markers") { appState.clearChangeMarkers() }
            Toggle("Word Wrap", isOn: Binding(get: { appState.settings.wordWrap },
                                              set: { v in var n = appState.settings; n.wordWrap = v; appState.updateSettings(n) }))
            Toggle("Highlight Current Line", isOn: appState.setting(\.highlightCurrentLine))
            Toggle("Show Indent Guides", isOn: appState.setting(\.showIndentGuides))
            Toggle("Show Invisible Characters", isOn: appState.setting(\.showInvisibles))
            Divider()
            Button("Zoom In") { appState.zoom(by: 1) }
                .keyboardShortcut(AppShortcut.zoomIn)
            Button("Zoom In") { appState.zoom(by: 1) }
                .keyboardShortcut(AppShortcut.zoomInAlternate)
            Button("Zoom Out") { appState.zoom(by: -1) }
                .keyboardShortcut(AppShortcut.zoomOut)
            Button("Zoom Out") { appState.zoom(by: -1) }
                .keyboardShortcut(AppShortcut.zoomOutAlternate)
            Button("Reset Font Size") { appState.resetZoom() }
                .keyboardShortcut(AppShortcut.resetZoom)
            Divider()
            Picker("Appearance", selection: Binding(get: { appState.settings.appearance },
                                                    set: { v in var n = appState.settings; n.appearance = v; appState.updateSettings(n) })) {
                ForEach(AppearanceMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("App Icon", selection: Binding(get: { appState.settings.appIcon },
                                                  set: { v in var n = appState.settings; n.appIcon = v; appState.updateSettings(n) })) {
                ForEach(AppIconStyle.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Background Pattern", selection: Binding(get: { appState.settings.backgroundPattern },
                                                            set: { v in var n = appState.settings; n.backgroundPattern = v; appState.updateSettings(n) })) {
                ForEach(BackgroundPattern.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        }
        CommandMenu("Tools") {
            Button("Command Palette…") { appState.togglePalette() }
                .keyboardShortcut(AppShortcut.commandPalette)
            Divider()
            Button("Translate Selection…") { appState.presentTranslation() }
            Button("Translate Document…") { appState.presentTranslation(wholeDocument: true) }
            Divider()
            Button("Send curl Request") { appState.sendCurlAtCursor() }
            Divider()
            ForEach(TextToolGroup.allCases, id: \.self) { group in
                Menu(group.title) {
                    ForEach(group.tools) { tool in
                        if tool.startsSubsection { Divider() }
                        Button(tool.title) { appState.run(tool) }
                    }
                }
            }
        }
    }
}
