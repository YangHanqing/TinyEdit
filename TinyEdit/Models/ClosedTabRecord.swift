import Foundation

/// No text field, ever. Reopen reads the file from disk.
struct ClosedTabRecord: Codable, Equatable, Sendable {
    var fileBookmark: Data
    var fileDisplayName: String
    var language: EditorLanguage
    var encoding: TextEncoding
    var lineEnding: LineEnding
    var cursorLocation: Int
    var selectionLength: Int
    var scrollPosition: Double
    var closedAt: Date
}
