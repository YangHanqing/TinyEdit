import AppKit

/// Which editor decorations are on, from `EditorSettings`. Bracket and occurrence highlights are always on.
struct EditorDecorationOptions: Equatable {
    var currentLine = true
    var indentGuides = true
    var invisibles = false
}

/// What the clip view paints beneath the text for the visible rect, in text-view coordinates. The clip
/// view converts them to its own coordinates when drawing. Beneath, so selection and text draw on top, and never
/// in the text storage, so none of it can be copied, undone or saved.
struct EditorDecorations: Equatable {
    struct Guide: Equatable {
        var x: CGFloat
        var minY: CGFloat
        var maxY: CGFloat
    }

    /// A Preview icon after a line of a JSON tab that holds a picture value. Clicking it previews that value.
    struct ImageMark: Equatable {
        /// The icon's hit and hover area.
        var rect: NSRect
        var valueRange: NSRange
        var hovered = false
    }

    /// The caret's line, painted across the whole width. Only with an empty selection.
    var currentLine: NSRect?
    /// The bracket at the caret and its partner, when on screen.
    var brackets: [NSRect] = []
    /// Other occurrences of the selected text on screen.
    var occurrences: [NSRect] = []
    var guides: [Guide] = []
    var imageMarks: [ImageMark] = []

    /// Selected text shorter than this, on one line, has its other occurrences marked.
    static let occurrenceMaxLength = 200
    static let occurrenceLimit = 500
}

extension EditorTextView {
    /// Decorations for the lines that intersect `visible`. Lays out only those lines.
    func decorations(in visible: NSRect) -> EditorDecorations {
        var result = EditorDecorations()
        guard visible.width > 0, visible.height > 0, let lm = textLayoutManager, let cs = textContentStorage,
              let text = cs.textStorage?.string as NSString? else { return result }
        let origin = textContainerOrigin
        let doc = cs.documentRange.location
        let drawingFont = font ?? EditorConfiguration.font(size: 13)
        let lineHeight = ceil(drawingFont.ascender - drawingFont.descender + drawingFont.leading)
        let sel = selectedRange()
        let caretOnly = selectedRanges.count == 1 && sel.length == 0

        // The visible paragraphs: their start offsets and frames.
        var fragments: [(start: Int, fragment: NSTextLayoutFragment)] = []
        if text.length > 0, let first = lm.textLayoutFragment(for: CGPoint(x: 0, y: max(visible.minY - origin.y, 0))) {
            lm.enumerateTextLayoutFragments(from: first.rangeInElement.location, options: [.ensuresLayout]) { fragment in
                if origin.y + fragment.layoutFragmentFrame.minY > visible.maxY { return false }
                fragments.append((cs.offset(from: doc, to: fragment.rangeInElement.location), fragment))
                return true
            }
        }
        let visibleStart = fragments.first?.start ?? 0
        let visibleEnd = fragments.last.map { $0.start + cs.offset(from: $0.fragment.rangeInElement.location, to: $0.fragment.rangeInElement.endLocation) } ?? 0

        if decorationOptions.currentLine, caretOnly {
            result.currentLine = caretLineRect(sel.location, text: text, fragments: fragments, origin: origin, lineHeight: lineHeight)
        }

        if caretOnly, let (near, far) = BracketMatcher.match(in: text, caret: sel.location) {
            for r in [near, far] where r.location >= visibleStart && NSMaxRange(r) <= visibleEnd {
                result.brackets += segmentRects(r, lm: lm, cs: cs, origin: origin)
            }
        }

        if selectedRanges.count == 1, (1...EditorDecorations.occurrenceMaxLength).contains(sel.length), NSMaxRange(sel) <= text.length {
            let needle = text.substring(with: sel)
            if !needle.contains("\n"), !needle.allSatisfy({ $0 == " " || $0 == "\t" }) {
                let wholeWord = needle.unicodeScalars.allSatisfy(Self.isWordScalar)
                var from = visibleStart
                while from < visibleEnd, result.occurrences.count < EditorDecorations.occurrenceLimit {
                    let r = text.range(of: needle, options: [.literal], range: NSRange(location: from, length: visibleEnd - from))
                    if r.location == NSNotFound { break }
                    from = NSMaxRange(r)
                    if r == sel { continue }
                    if wholeWord, !isWordBoundary(text, r) { continue }
                    result.occurrences += segmentRects(r, lm: lm, cs: cs, origin: origin)
                }
            }
        }

        if decorationOptions.indentGuides, !fragments.isEmpty {
            result.guides = indentGuides(text: text, fragments: fragments, origin: origin, font: drawingFont)
        }

        if let images = jsonImageValues?(), !images.isEmpty, !fragments.isEmpty {
            result.imageMarks = imageMarks(images, text: text, fragments: fragments, origin: origin,
                                           font: drawingFont, caret: sel.location)
        }
        return result
    }

    /// One icon per visible paragraph that holds a picture value, after its last character: for the value
    /// at the caret when it is on that paragraph, else for the first. Not drawn when it would not fit.
    private func imageMarks(_ images: [JSONImageValue], text: NSString, fragments: [(start: Int, fragment: NSTextLayoutFragment)],
                            origin: NSPoint, font: NSFont, caret: Int) -> [EditorDecorations.ImageMark] {
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        let mouse = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        var next = images.partitioningIndex { $0.valueRange.location >= fragments[0].start }
        var marks: [EditorDecorations.ImageMark] = []
        for (start, fragment) in fragments {
            let end = start + fragment.rangeInElement.length(in: textContentStorage)
            var here: [JSONImageValue] = []
            while next < images.count, images[next].valueRange.location < end {
                if images[next].valueRange.location >= start { here.append(images[next]) }
                next += 1
            }
            guard let first = here.first else { continue }
            let image = here.first { $0.valueRange.location <= caret && caret <= NSMaxRange($0.valueRange) } ?? first
            var contentEnd = end
            if contentEnd > start, text.character(at: contentEnd - 1) == 0x0A { contentEnd -= 1 }
            let offset = contentEnd - start
            let lines = fragment.textLineFragments
            guard let line = lines.first(where: { NSLocationInRange(offset, $0.characterRange) })
                ?? lines.last(where: { $0.characterRange.length > 0 }) else { continue }
            let frame = fragment.layoutFragmentFrame
            let bounds = line.typographicBounds
            let x = origin.x + frame.minX + bounds.minX + line.locationForCharacter(at: offset).x
            let side = ceil(min(bounds.height, font.pointSize * 1.3))
            let rect = NSRect(x: (x + max(space, 6)).rounded(), y: (origin.y + frame.minY + bounds.minY + (bounds.height - side) / 2).rounded(),
                              width: side + 6, height: side)
            guard rect.maxX <= self.bounds.width - 2 else { continue }
            marks.append(.init(rect: rect, valueRange: image.valueRange, hovered: mouse.map(rect.contains) ?? false))
        }
        return marks
    }

    // MARK: Parts

    /// The caret's visual line. After a final newline (or in an empty document) the caret is on the extra
    /// line below the last paragraph.
    private func caretLineRect(_ caret: Int, text: NSString, fragments: [(start: Int, fragment: NSTextLayoutFragment)],
                               origin: NSPoint, lineHeight: CGFloat) -> NSRect? {
        let onExtraLine = caret == text.length && (text.length == 0 || text.character(at: text.length - 1) == 0x0A)
        if onExtraLine {
            guard text.length > 0 else { return NSRect(x: 0, y: origin.y, width: 0, height: lineHeight) }
            guard let last = fragments.last, last.start + last.fragment.rangeInElement.length(in: textContentStorage) == text.length
            else { return nil }
            let frame = last.fragment.layoutFragmentFrame
            if let extra = last.fragment.textLineFragments.last, last.fragment.textLineFragments.count > 1, extra.characterRange.length == 0 {
                return NSRect(x: 0, y: origin.y + frame.minY + extra.typographicBounds.minY, width: 0, height: extra.typographicBounds.height)
            }
            return NSRect(x: 0, y: origin.y + frame.maxY, width: 0, height: lineHeight)
        }
        for (start, fragment) in fragments {
            let length = fragment.rangeInElement.length(in: textContentStorage)
            guard caret >= start, caret < start + length || (caret == start + length && caret == text.length) else { continue }
            let offset = caret - start
            let frame = fragment.layoutFragmentFrame
            let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
            let line = lines.first { NSLocationInRange(offset, $0.characterRange) } ?? lines.last
            guard let line else { return nil }
            return NSRect(x: 0, y: origin.y + frame.minY + line.typographicBounds.minY, width: 0, height: line.typographicBounds.height)
        }
        return nil
    }

    private func segmentRects(_ range: NSRange, lm: NSTextLayoutManager, cs: NSTextContentStorage, origin: NSPoint) -> [NSRect] {
        guard let tr = cs.textRange(for: range) else { return [] }
        var rects: [NSRect] = []
        lm.enumerateTextSegments(in: tr, type: .highlight, options: []) { _, frame, _, _ in
            if frame.width > 0 { rects.append(frame.offsetBy(dx: origin.x, dy: origin.y)) }
            return true
        }
        return rects
    }

    /// One guide per indent level of each visible paragraph, at the left edge of that level's column. A blank
    /// line takes the smaller indent of its neighbors, so guides run through blank lines inside a block.
    private func indentGuides(text: NSString, fragments: [(start: Int, fragment: NSTextLayoutFragment)],
                              origin: NSPoint, font: NSFont) -> [EditorDecorations.Guide] {
        let style = indentStyle?() ?? .spaces(tabWidth)
        let width: Int
        switch style {
        case .tabs: width = max(tabWidth, 1)
        case .spaces(let n): width = max(n, 1)
        }
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        let tw = max(tabWidth, 1)
        var columns: [Int?] = fragments.map { start, _ in
            var i = start, column = 0
            while i < text.length, i - start < 400 {
                let u = text.character(at: i)
                if u == 0x20 { column += 1 } else if u == 0x09 { column = (column / tw + 1) * tw } else { break }
                i += 1
            }
            return i >= text.length || text.character(at: i) == 0x0A ? nil : column
        }
        // Blank lines: the smaller of the nearest non-blank indents above and below.
        var above: Int?
        var filled = columns
        for k in columns.indices {
            if let c = columns[k] { above = c; continue }
            let below = columns[(k + 1)...].lazy.compactMap { $0 }.first
            filled[k] = [above, below].compactMap { $0 }.min() ?? 0
        }
        columns = filled

        var guides: [EditorDecorations.Guide] = []
        for (k, (_, fragment)) in fragments.enumerated() {
            let levels = (columns[k] ?? 0) / width
            guard levels > 0 else { continue }
            let frame = fragment.layoutFragmentFrame
            let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
            let minY = origin.y + frame.minY + (lines.first?.typographicBounds.minY ?? 0)
            let maxY = origin.y + frame.minY + (lines.last?.typographicBounds.maxY ?? frame.height)
            for level in 0..<levels {
                let x = (origin.x + frame.minX + CGFloat(level * width) * space).rounded(.down) + 0.5
                guides.append(.init(x: x, minY: minY, maxY: maxY))
            }
        }
        return guides
    }

    private static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        s == "_" || CharacterSet.alphanumerics.contains(s)
    }

    private func isWordBoundary(_ text: NSString, _ r: NSRange) -> Bool {
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < text.length, let s = Unicode.Scalar(text.character(at: i)) else { return false }
            return Self.isWordScalar(s)
        }
        return !isWord(r.location - 1) && !isWord(NSMaxRange(r))
    }
}

private extension Array {
    /// The first index whose element satisfies `predicate`, which is false then true across the array.
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if predicate(self[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}

private extension NSTextRange {
    func length(in cs: NSTextContentStorage?) -> Int {
        cs?.offset(from: location, to: endLocation) ?? 0
    }
}

@MainActor
enum EditorDecorationDrawing {
    /// Painted after the background pattern, beneath the text. `width` spans the clip view.
    static func draw(_ d: EditorDecorations, in bounds: NSRect, dirtyRect: NSRect) {
        if let line = d.currentLine {
            let r = NSRect(x: bounds.minX, y: line.minY, width: bounds.width, height: line.height)
            if r.intersects(dirtyRect) {
                Theme.currentLine.setFill()
                r.fill()
            }
        }
        if !d.guides.isEmpty {
            let path = NSBezierPath()
            path.lineWidth = 1
            for g in d.guides where g.maxY >= dirtyRect.minY && g.minY <= dirtyRect.maxY {
                path.move(to: NSPoint(x: g.x, y: g.minY))
                path.line(to: NSPoint(x: g.x, y: g.maxY))
            }
            Theme.indentGuide.setStroke()
            path.stroke()
        }
        for r in d.occurrences where r.intersects(dirtyRect) {
            Theme.occurrenceHighlight.setFill()
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        }
        for mark in d.imageMarks where mark.rect.intersects(dirtyRect) {
            drawImageMark(mark)
        }
        for r in d.brackets where r.intersects(dirtyRect) {
            let box = r.insetBy(dx: 0.5, dy: 0.5)
            Theme.bracketMatch.setFill()
            NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2).fill()
            Theme.bracketMatchBorder.setStroke()
            let outline = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    /// A photo symbol in the accent color, on a chip while the pointer is over it.
    private static func drawImageMark(_ mark: EditorDecorations.ImageMark) {
        if mark.hovered {
            Theme.occurrenceHighlight.setFill()
            NSBezierPath(roundedRect: mark.rect, xRadius: 4, yRadius: 4).fill()
        }
        // Resolved here, in the view's appearance: the symbol's palette does not follow a dynamic color.
        let color = Theme.accent.usingColorSpace(.sRGB) ?? Theme.accent
        let config = NSImage.SymbolConfiguration(pointSize: (mark.rect.height * 0.72).rounded(), weight: .medium)
            .applying(.init(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        else { return }
        let size = symbol.size
        let r = NSRect(x: (mark.rect.midX - size.width / 2).rounded(), y: (mark.rect.midY - size.height / 2).rounded(),
                       width: size.width, height: size.height)
        symbol.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
