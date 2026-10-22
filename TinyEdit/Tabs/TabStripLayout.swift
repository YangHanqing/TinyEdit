import CoreGraphics

/// Tab widths and scroll targets for the tab bar. The tabs share the bar's width between `minWidth`
/// and `maxWidth`; the selected tab keeps at least `selectedMinWidth`. Tabs that do not fit at their
/// minimum make the bar scroll. Pure, so the arithmetic is tested without a window.
struct TabStripLayout: Equatable {
    static let minWidth: CGFloat = 100
    static let maxWidth: CGFloat = 180
    static let selectedMinWidth: CGFloat = 140
    static let spacing: CGFloat = 2
    /// Inside the scroll content, before the first tab and after the last.
    static let padding: CGFloat = 6
    /// A revealed tab stops this far inside the strip's edge, clear of the edge fade, so the next tab
    /// peeks out from under it.
    static let revealMargin: CGFloat = 24

    let count: Int
    let selectedIndex: Int?
    /// Every tab but the selected one.
    let width: CGFloat
    let selectedWidth: CGFloat

    init(available: CGFloat, count: Int, selectedIndex: Int?) {
        self.count = count
        self.selectedIndex = selectedIndex.flatMap { (0..<count).contains($0) ? $0 : nil }
        let inner = available - 2 * Self.padding - Self.spacing * CGFloat(max(count - 1, 0))
        let share = Self.clamp(inner / CGFloat(max(count, 1)))
        if self.selectedIndex != nil, share < Self.selectedMinWidth {
            selectedWidth = Self.selectedMinWidth
            width = count > 1 ? Self.clamp((inner - Self.selectedMinWidth) / CGFloat(count - 1)) : share
        } else {
            selectedWidth = share
            width = share
        }
    }

    private static func clamp(_ w: CGFloat) -> CGFloat {
        min(max(w.rounded(.down), minWidth), maxWidth)
    }

    func width(at index: Int) -> CGFloat { index == selectedIndex ? selectedWidth : width }

    var contentWidth: CGFloat {
        guard count > 0 else { return 2 * Self.padding }
        let tabs = CGFloat(count - (selectedIndex == nil ? 0 : 1)) * width + (selectedIndex == nil ? 0 : selectedWidth)
        return 2 * Self.padding + tabs + Self.spacing * CGFloat(count - 1)
    }

    func overflows(_ available: CGFloat) -> Bool { contentWidth > available + 0.5 }

    /// Leading and trailing x of a tab in the scroll content.
    func span(of index: Int) -> ClosedRange<CGFloat> {
        var x = Self.padding + (Self.spacing + width) * CGFloat(index)
        if let s = selectedIndex, s < index { x += selectedWidth - width }
        return x...(x + width(at: index))
    }

    /// The scroll offset that brings a tab into view with the least movement, `revealMargin` from the
    /// edge (the first and last tabs go to the ends), or nil when it is already clear of the edges.
    func offset(revealing index: Int, from offset: CGFloat, viewport: CGFloat) -> CGFloat? {
        guard (0..<count).contains(index) else { return nil }
        let span = span(of: index)
        let lead = span.lowerBound - Self.revealMargin
        let trail = span.upperBound + Self.revealMargin
        if lead < offset { return clampOffset(lead, viewport: viewport) }
        if trail > offset + viewport { return clampOffset(trail - viewport, viewport: viewport) }
        return nil
    }

    func clampOffset(_ x: CGFloat, viewport: CGFloat) -> CGFloat {
        min(max(x, 0), max(contentWidth - viewport, 0))
    }
}
