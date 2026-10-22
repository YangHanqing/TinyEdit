import CoreGraphics

/// Column widths for a preview table, like a browser's automatic table layout: when every column
/// fits on one line it keeps that width; otherwise the narrow columns keep theirs and the wide ones
/// share what is left at one level and wrap. Only when every column is down to its minimum does
/// the table scroll. Pure, so the arithmetic is tested without a window.
enum MarkdownTableLayout {
    /// Below this a wrapping column holds a word or two; a narrower one-line column keeps its width.
    static let minColumnWidth: CGFloat = 96

    /// `natural` is each column's one-line text width, `available` the width left for text.
    static func widths(natural: [CGFloat], available: CGFloat) -> [CGFloat] {
        let natural = natural.map { max(0, $0.rounded(.up)) }
        guard natural.reduce(0, +) > available else { return natural }
        let minimum = natural.map { min($0, minColumnWidth) }
        guard minimum.reduce(0, +) < available else { return minimum }
        // Each column takes the level clamped to its [minimum, natural]. The total is linear between
        // those breakpoints, so the level that fills `available` is found exactly in one segment.
        func total(_ level: CGFloat) -> CGFloat {
            zip(minimum, natural).reduce(0) { $0 + min($1.1, max($1.0, level)) }
        }
        let points = Set(minimum + natural).sorted()
        var level: CGFloat = 0
        for (low, high) in zip(points, points.dropFirst()) where total(high) >= available {
            level = low + (available - total(low)) / (total(high) - total(low)) * (high - low)
            break
        }
        return zip(minimum, natural).map { min($1, max($0, level)).rounded(.down) }
    }
}
