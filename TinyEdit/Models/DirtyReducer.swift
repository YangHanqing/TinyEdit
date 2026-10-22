import Foundation

enum DirtyReducer {
    /// `lastSavedContentHash == nil` means Untitled, never baselined.
    static func isDirty(currentLogicalHash: String, lastSavedContentHash: String?) -> Bool {
        if let lastSavedContentHash {
            return currentLogicalHash != lastSavedContentHash
        }
        return currentLogicalHash != ContentHash.emptyStringHex
    }
}
