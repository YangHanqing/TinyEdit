import SwiftUI

/// Shows which app opens each common text format and offers to make TinyEdit the default.
/// Re-reads Launch Services whenever the app becomes active, so a change made in Finder's
/// Get Info shows up on return.
struct DefaultAppSettingsPane: View {
    @State private var model = DefaultAppModel()

    var body: some View {
        let pending = model.pendingFormats
        Form {
            Section {
                LabeledContent {
                    Button("Make Default for All") {
                        Task { await model.makeDefault(pending) }
                    }
                    .disabled(pending.isEmpty || model.isChanging)
                } label: {
                    Text(summary(pending: pending.count))
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("macOS asks you to confirm each change. To choose another app later, use Get Info on a file in Finder, then Open With ▸ Change All.")
                    if let error = model.lastError {
                        Text(error).foregroundStyle(Color.error)
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                ForEach(model.formats) { format in
                    FormatRow(format: format,
                              handler: model.handlers[format.id],
                              isTinyEdit: model.opensWithTinyEdit(format),
                              disabled: model.isChanging) {
                        Task { await model.makeDefault([format]) }
                    }
                }
            } header: {
                Text("Formats")
            }
        }
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    private func summary(pending: Int) -> String {
        let total = model.formats.count
        if pending == 0 { return String(localized: "TinyEdit opens all of these formats.") }
        return String(localized: "TinyEdit opens \(total - pending) of \(total) formats.")
    }
}

private struct FormatRow: View {
    let format: DefaultAppFormat
    let handler: URL?
    let isTinyEdit: Bool
    let disabled: Bool
    let makeDefault: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if isTinyEdit {
                    Label("Default", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(Color.success)
                } else {
                    currentApp
                    Button("Make Default", action: makeDefault).disabled(disabled)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: format.name)
                Text(verbatim: format.extensions)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    @ViewBuilder private var currentApp: some View {
        if let handler {
            HStack(spacing: 4) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: handler.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(verbatim: Self.appName(handler))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Color.textSecondary)
            .toolTip(handler.path)
        } else {
            Text("No default app").foregroundStyle(Color.textTertiary)
        }
    }

    /// The localized name Finder shows, without ".app" when Finder shows extensions.
    private static func appName(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
