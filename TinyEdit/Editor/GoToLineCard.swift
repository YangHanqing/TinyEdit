import SwiftUI

/// ⌘L: a small card in the find card's place. Takes "line" or "line:column"; Return goes there and closes,
/// Escape closes. Input that is not a line number outlines the field in red.
struct GoToLineCard: View {
    @Environment(AppState.self) private var appState
    @State private var input = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if appState.goToLineVisible {
                card
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 22)
        .padding(.top, appState.goToLineVisible ? 10 : 0)
        .animation(.easeOut(duration: 0.18), value: appState.goToLineVisible)
    }

    private var card: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right.to.line")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accent)
            FieldBox(focused: focused, alert: invalid) {
                TextField("Go to line", text: $input)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(submit)
            }
            .frame(width: 150)
            Text(verbatim: "/ \(appState.activeLineCount)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Color.textSecondary)
                .fixedSize()
            CloseButton(label: String(localized: "Close")) { appState.hideGoToLine() }
        }
        .floatingCard()
        .background {
            Button("") { appState.hideGoToLine() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .toolTip(String(localized: "Line number, or line:column"))
        .onChange(of: input) { _, _ in invalid = false }
        .onChange(of: appState.goToLineFocusToken) { _, _ in focused = true }
        .onAppear {
            input = ""
            invalid = false
            focused = true
        }
    }

    private func submit() {
        if appState.goToLine(input) {
            appState.hideGoToLine()
        } else {
            invalid = !input.isEmpty
        }
    }
}
