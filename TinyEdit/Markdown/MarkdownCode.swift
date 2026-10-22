import SwiftUI

/// Share the editor's language scanners and theme. Unknown fence labels remain plain text.
enum MarkdownCode {
    static func language(_ hint: String?) -> EditorLanguage {
        guard let name = hint?.split(whereSeparator: \.isWhitespace).first?.lowercased() else { return .plain }
        let aliases: [String: EditorLanguage] = ["js": .javascript, "ts": .typescript, "py": .python,
            "sh": .shell, "bash": .shell, "zsh": .shell, "cs": .csharp, "c#": .csharp,
            "c++": .cpp, "yml": .yaml, "text": .plain, "txt": .plain, "plaintext": .plain]
        return aliases[name] ?? EditorLanguage(rawValue: name) ?? EditorLanguage.from(fileExtension: name)
    }

    static func spans(_ code: String, hint: String?) -> [HighlightSpan] {
        guard code.utf8.count <= HighlightPolicy.fullLimit else { return [] }
        return SyntaxHighlighter.spans(language: language(hint), text: code, limit: nil)
    }

    @MainActor static func styled(_ code: String, spans: [HighlightSpan]) -> NSAttributedString {
        let value = NSMutableAttributedString(attributedString: MarkdownText.plain(code,
            font: .monospacedSystemFont(ofSize: 12, weight: .regular)))
        for span in spans where span.range.location >= 0 && NSMaxRange(span.range) <= value.length {
            value.addAttribute(.foregroundColor, value: span.kind.color, range: span.range)
        }
        return value
    }
}

struct MarkdownCodeView: View {
    let language: String?
    let code: String
    @State private var spans: [HighlightSpan] = []
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy Code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                }
                .font(.caption).buttonStyle(.borderless)
                .task(id: copied) {
                    if copied {
                        try? await Task.sleep(for: .seconds(2))
                        if !Task.isCancelled { copied = false }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            ScrollView(.horizontal) {
                MarkdownTextView(text: MarkdownCode.styled(code, spans: spans), wraps: false)
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .task(id: "\(language ?? "")|\(code)") {
            spans = []
            copied = false
            let result = await Task.detached(priority: .utility) { MarkdownCode.spans(code, hint: language) }.value
            if !Task.isCancelled { spans = result }
        }
    }
}
