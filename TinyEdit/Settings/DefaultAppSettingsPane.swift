import SwiftUI

/// Shows which app opens each common text format. TinyEdit cannot make itself the default from the
/// sandbox, so each row shows an example file in Finder for Get Info ▸ Open With ▸ Change All.
/// Re-reads Launch Services whenever the app becomes active, so the change shows up on return.
struct DefaultAppSettingsPane: View {
    @State private var model = DefaultAppModel()

    var body: some View {
        Form {
            Section {
                Text(summary(pending: model.pendingFormats.count))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Only you can change which app opens a format. Click Reveal in Finder, press ⌘I, choose TinyEdit under Open With, then click Change All.")
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
                              isTinyEdit: model.opensWithTinyEdit(format)) {
                        model.revealExample(for: format)
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
    let reveal: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if isTinyEdit {
                    Label("Default", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(Color.success)
                } else {
                    currentApp
                    Button("Reveal in Finder", action: reveal)
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
