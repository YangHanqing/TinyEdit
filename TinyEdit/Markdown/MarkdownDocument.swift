import Foundation

/// A rendered Markdown block. Structure lives in the tree; inline text carries only
/// text styles, links and image references.
enum MarkdownNode: Sendable, Equatable {
    case paragraph(AttributedString)
    case heading(level: Int, text: AttributedString)
    case codeBlock(language: String?, code: String)
    case blockQuote([MarkdownNode])
    case list(MarkdownList)
    case table(MarkdownTable)
    case thematicBreak
    /// Raw HTML block. It is shown as source and never interpreted.
    case html(String)
}

struct MarkdownList: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        var ordinal: Int
        var blocks: [MarkdownNode]
        /// GFM task item: false open, true done, nil not a task. The box is removed from `blocks`.
        var task: Bool? = nil
    }
    var ordered: Bool
    var items: [Item]
}

struct MarkdownTable: Sendable, Equatable {
    enum Alignment: Sendable, Equatable { case leading, center, trailing }
    var columns: [Alignment]
    var header: [AttributedString]
    /// Every row has exactly `columns.count` cells; missing cells are empty.
    var rows: [[AttributedString]]
}

/// Foundation parses; this only reshapes its output. Each run's `presentationIntent` is the path from
/// its innermost block to the document root, with an identity per block. Stage one rebuilds that tree
/// exactly, stage two gives each node a type from its own kind and its children, never from flags
/// gathered off its ancestors.
enum MarkdownDocument {
    static func parse(_ source: String) throws -> [MarkdownNode] {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.appliesSourcePositionAttributes = true
        options.failurePolicy = .returnPartiallyParsedIfPossible
        let rendered = try AttributedString(markdown: source, options: options)
        return blocks(IntentNode.tree(rendered, source: source).children)
    }

    // MARK: Stage one: the intent tree

    private final class IntentNode {
        enum Child { case node(IntentNode), text(AttributedString) }

        let kind: PresentationIntent.Kind?
        let identity: Int
        var children: [Child] = []

        init(kind: PresentationIntent.Kind?, identity: Int) {
            self.kind = kind
            self.identity = identity
        }

        /// Runs arrive in document order and identities are unique per parse, so a run either
        /// continues the last child at each level or opens a new one.
        static func tree(_ rendered: AttributedString, source: String) -> IntentNode {
            let root = IntentNode(kind: nil, identity: -1)
            var recoveredImages: Set<AttributedString.MarkdownSourcePosition> = []
            for run in rendered.runs {
                let original = AttributedString(rendered[run.range])
                let recovered = MarkdownInline.linkedImage(original, source: source)
                if recovered != nil, let position = run.markdownSourcePosition,
                   !recoveredImages.insert(position).inserted { continue }
                var node = root
                for component in (run.presentationIntent?.components ?? []).reversed() {
                    if case .node(let last) = node.children.last, last.identity == component.identity {
                        node = last
                    } else {
                        let child = IntentNode(kind: component.kind, identity: component.identity)
                        node.children.append(.node(child))
                        node = child
                    }
                }
                // Keep inline semantics, including native image URLs and the supported HTML subset.
                let slice = MarkdownInline.sanitized(recovered ?? original)
                if case .text(let text) = node.children.last {
                    node.children[node.children.count - 1] = .text(text + slice)
                } else {
                    node.children.append(.text(slice))
                }
            }
            return root
        }

        var text: AttributedString {
            children.reduce(into: AttributedString()) { result, child in
                if case .text(let text) = child { result.append(text) }
            }
        }
    }

    // MARK: Stage two: typed nodes

    private static func blocks(_ children: [IntentNode.Child]) -> [MarkdownNode] {
        children.flatMap { child -> [MarkdownNode] in
            switch child {
            case .text(let text): [looseText(text)]
            case .node(let node): blocks(node)
            }
        }
    }

    private static func blocks(_ node: IntentNode) -> [MarkdownNode] {
        guard let kind = node.kind else { return blocks(node.children) }
        switch kind {
        case .paragraph:
            return [.paragraph(node.text)]
        case .header(let level):
            return [.heading(level: level, text: node.text)]
        case .codeBlock(let hint):
            var code = String(node.text.characters)
            if code.hasSuffix("\n") { code.removeLast() }
            return [.codeBlock(language: hint, code: code)]
        case .blockQuote:
            return [.blockQuote(blocks(node.children))]
        case .orderedList:
            return [.list(list(node, ordered: true))]
        case .unorderedList:
            return [.list(list(node, ordered: false))]
        case .table(let columns):
            return [.table(table(node, columns: columns))]
        case .thematicBreak:
            return [.thematicBreak]
        case .listItem, .tableHeaderRow, .tableRow, .tableCell:
            // Only reachable outside their container; keep the content rather than drop it.
            return blocks(node.children)
        @unknown default:
            return blocks(node.children)
        }
    }

    /// Text attached directly to a container rather than to a leaf block. Foundation does this for
    /// HTML blocks, which carry no block intent of their own.
    private static func looseText(_ text: AttributedString) -> MarkdownNode {
        let isHTML = text.runs.allSatisfy { $0.inlinePresentationIntent?.contains(.blockHTML) == true }
        guard isHTML else { return .paragraph(text) }
        var source = String(text.characters)
        while source.hasSuffix("\n") { source.removeLast() }
        return .html(source)
    }

    private static func list(_ node: IntentNode, ordered: Bool) -> MarkdownList {
        let items = node.children.enumerated().map { index, child -> MarkdownList.Item in
            if case .node(let item) = child, case .listItem(let ordinal) = item.kind {
                return taskItem(MarkdownList.Item(ordinal: ordinal, blocks: blocks(item.children)))
            }
            return MarkdownList.Item(ordinal: index + 1, blocks: blocks([child]))
        }
        return MarkdownList(ordered: ordered, items: items)
    }

    /// Foundation has no task intent: `[ ]`, `[x]` or `[X]` stays literal text at the start of the item's first
    /// paragraph. Followed by a blank or ending the paragraph, it becomes the item's box, as in the editor.
    private static func taskItem(_ item: MarkdownList.Item) -> MarkdownList.Item {
        guard case .paragraph(let text) = item.blocks.first else { return item }
        let chars = text.characters
        let head = Array(chars.prefix(4))
        guard head.count >= 3, head[0] == "[", head[2] == "]", [" ", "x", "X"].contains(head[1]),
              head.count == 3 || head[3].isWhitespace else { return item }
        var result = item
        result.task = head[1] != " "
        let rest = AttributedString(text[chars.index(chars.startIndex, offsetBy: head.count)...])
        if rest.characters.isEmpty {
            result.blocks.removeFirst()
        } else {
            result.blocks[0] = .paragraph(rest)
        }
        return result
    }

    private static func table(_ node: IntentNode, columns: [PresentationIntent.TableColumn]) -> MarkdownTable {
        var header: [AttributedString] = Array(repeating: AttributedString(), count: columns.count)
        var rows: [[AttributedString]] = []
        for case .node(let row) in node.children {
            var cells = Array(repeating: AttributedString(), count: columns.count)
            for case .node(let cell) in row.children {
                if case .tableCell(let column) = cell.kind, cells.indices.contains(column) {
                    cells[column] = cell.text
                }
            }
            if case .tableHeaderRow = row.kind { header = cells } else { rows.append(cells) }
        }
        return MarkdownTable(columns: columns.map { alignment($0.alignment) }, header: header, rows: rows)
    }

    private static func alignment(_ alignment: PresentationIntent.TableColumn.Alignment) -> MarkdownTable.Alignment {
        switch alignment {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        @unknown default: .leading
        }
    }
}
