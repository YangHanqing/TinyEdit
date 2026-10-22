import AppKit
import SwiftUI

/// Small vector patterns, drawn only within the viewport. No image assets or document changes.
@MainActor
enum BackgroundPatternDrawing {
    static func draw(_ pattern: BackgroundPattern, dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        dirtyRect.fill()
        guard pattern != .off else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: dirtyRect).addClip()
        // Anchor to document coordinates so partial redraws and scroll copies share the same phase.
        let visible = dirtyRect
        let path = NSBezierPath()

        switch pattern {
        case .off: break
        case .dots:
            let step: CGFloat = 24
            for y in stride(from: floor(visible.minY / step) * step, through: visible.maxY + step, by: step) {
                for x in stride(from: floor(visible.minX / step) * step, through: visible.maxX + step, by: step) {
                    path.appendOval(in: NSRect(x: x + 12, y: y + 12, width: 1.5, height: 1.5))
                }
            }
            Theme.backgroundPattern.withAlphaComponent(0.8).setFill()
            path.fill()
        case .grid:
            let step: CGFloat = 28
            for x in stride(from: floor(visible.minX / step) * step, through: visible.maxX, by: step) {
                path.move(to: NSPoint(x: x, y: visible.minY))
                path.line(to: NSPoint(x: x, y: visible.maxY))
            }
            for y in stride(from: floor(visible.minY / step) * step, through: visible.maxY, by: step) {
                path.move(to: NSPoint(x: visible.minX, y: y))
                path.line(to: NSPoint(x: visible.maxX, y: y))
            }
            Theme.backgroundPattern.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        case .waves:
            let period: CGFloat = 120
            let row: CGFloat = 36
            for y in stride(from: floor((visible.minY - 6) / row) * row, through: visible.maxY + 6, by: row) {
                let startX = floor(visible.minX / period) * period
                path.move(to: NSPoint(x: startX, y: y))
                for x in stride(from: startX, through: visible.maxX, by: period) {
                    path.curve(to: NSPoint(x: x + period / 2, y: y),
                               controlPoint1: NSPoint(x: x + period / 6, y: y + 6),
                               controlPoint2: NSPoint(x: x + period / 3, y: y + 6))
                    path.curve(to: NSPoint(x: x + period, y: y),
                               controlPoint1: NSPoint(x: x + period * 2 / 3, y: y - 6),
                               controlPoint2: NSPoint(x: x + period * 5 / 6, y: y - 6))
                }
            }
            Theme.backgroundPattern.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 0.7
            path.stroke()
        }
    }
}

/// Owns the editor surface so patterns also cover the empty area below the text.
final class EditorBackgroundClipView: NSClipView {
    var pattern = BackgroundPattern.dots {
        didSet { if pattern != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = true
        backgroundColor = Theme.editorBackground
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Current line, bracket pair, occurrences and indent guides, beneath the transparent text view.
    var decorations = EditorDecorations() {
        didSet { if decorations != oldValue { needsDisplay = true } }
    }

    /// Decorations arrive in document-view coordinates. The clip and document origins can differ;
    /// scrolling and AppKit layout must not turn that difference into a highlight offset.
    private var decorationsForDrawing: EditorDecorations {
        guard let documentView else { return EditorDecorations() }
        var result = decorations
        result.currentLine = decorations.currentLine.map { convert($0, from: documentView) }
        result.occurrences = decorations.occurrences.map { convert($0, from: documentView) }
        result.brackets = decorations.brackets.map { convert($0, from: documentView) }
        result.valueMarks = decorations.valueMarks.map { mark in
            var m = mark
            m.rect = convert(mark.rect, from: documentView)
            return m
        }
        result.guides = decorations.guides.map { guide in
            let top = convert(NSPoint(x: guide.x, y: guide.minY), from: documentView)
            let bottom = convert(NSPoint(x: guide.x, y: guide.maxY), from: documentView)
            return .init(x: top.x, minY: min(top.y, bottom.y), maxY: max(top.y, bottom.y))
        }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        BackgroundPatternDrawing.draw(pattern, dirtyRect: dirtyRect)
        EditorDecorationDrawing.draw(decorationsForDrawing, in: bounds, dirtyRect: dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class PatternSurface: NSView {
    var pattern = BackgroundPattern.dots {
        didSet { if pattern != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        BackgroundPatternDrawing.draw(pattern, dirtyRect: dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The editor's surface, previewed in Settings beneath interactive content.
struct EditorBackground: NSViewRepresentable {
    let pattern: BackgroundPattern

    func makeNSView(context: Context) -> NSView { PatternSurface() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PatternSurface)?.pattern = pattern
    }
}
