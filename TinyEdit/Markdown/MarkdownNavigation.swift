import SwiftUI

/// GitHub-style heading fragments for everyday documents, generated in document order.
/// Paths identify nested headings without changing the parser's inline attributes.
struct MarkdownNavigation {
    struct Target: Equatable {
        var topLevel: Int
        var path: String
    }
    var targets: [String: Target] = [:]

    init(_ blocks: [MarkdownNode]) {
        var used: Set<String> = []
        func visit(_ nodes: [MarkdownNode], prefix: String, top: Int?) {
            for (index, node) in nodes.enumerated() {
                let path = prefix.isEmpty ? "\(index)" : "\(prefix).\(index)"
                switch node {
                case .heading(_, let text):
                    let base = Self.slug(String(text.characters))
                    var slug = base
                    var suffix = 0
                    while used.contains(slug) { suffix += 1; slug = "\(base)-\(suffix)" }
                    used.insert(slug)
                    targets[slug] = Target(topLevel: top ?? index, path: path)
                case .blockQuote(let children): visit(children, prefix: path, top: top ?? index)
                case .list(let list):
                    for (item, value) in list.items.enumerated() {
                        visit(value.blocks, prefix: "\(path).\(item)", top: top ?? index)
                    }
                default: break
                }
            }
        }
        visit(blocks, prefix: "", top: nil)
    }

    static func slug(_ title: String) -> String {
        let scalars = title.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
                || $0 == "-" || $0 == "_" || CharacterSet.whitespaces.contains($0)
        }
        return String(String.UnicodeScalarView(scalars)).map { $0.isWhitespace ? "-" : String($0) }.joined()
    }

    func target(for url: URL) -> Target? {
        // Decode once. A literal percent in a heading must not be decoded a second time.
        guard url.relativeString.hasPrefix("#"),
              let fragment = String(url.relativeString.dropFirst()).removingPercentEncoding else { return nil }
        return targets[fragment.precomposedStringWithCanonicalMapping]
    }
}

/// SwiftUI's lazy reader can reveal a top-level row, but cannot reliably locate a heading deep
/// inside that row. A native layout anchor finishes the jump after that row has been laid out.
@MainActor final class MarkdownHeadingRegistry {
    private final class WeakView {
        weak var value: NSView?
        init(_ value: NSView) { self.value = value }
    }
    private var views: [String: WeakView] = [:]
    private var pending: String?

    func register(_ view: NSView, path: String) {
        views[path] = WeakView(view)
        finishJump()
    }

    func canLocate(_ path: String) -> Bool { views[path]?.value?.window != nil }

    func jump(to path: String) {
        pending = path
        finishJump()
    }

    func cancelJump() { pending = nil }
    func reset() { pending = nil; views.removeAll() }

    private func finishJump() {
        guard let path = pending else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.pending == path,
                  let view = self.views[path]?.value, view.window != nil,
                  let scroll = view.enclosingScrollView, let document = scroll.documentView else { return }
            document.layoutSubtreeIfNeeded()
            let rect = view.convert(view.bounds, to: document)
            let clip = scroll.contentView
            let top = document.isFlipped ? rect.minY : rect.maxY - clip.bounds.height
            let y = max(document.bounds.minY, min(top, document.bounds.maxY - clip.bounds.height))
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scroll.reflectScrolledClipView(clip)
            self.pending = nil
        }
    }
}

struct MarkdownHeadingAnchor: NSViewRepresentable {
    let path: String
    let registry: MarkdownHeadingRegistry?

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView { AnchorView() }
    func updateNSView(_ view: NSView, context: Context) { registry?.register(view, path: path) }
}

extension EnvironmentValues {
    @Entry var markdownHeadingRegistry: MarkdownHeadingRegistry? = nil
}
