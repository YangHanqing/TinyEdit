import XCTest
@testable import TinyEdit

final class DirtyStateTests: XCTestCase {
    func testEmptyUntitledIsClean() {
        XCTAssertFalse(DirtyReducer.isDirty(currentLogicalHash: ContentHash.emptyStringHex, lastSavedContentHash: nil))
    }
    func testNonEmptyUntitledIsDirty() {
        XCTAssertTrue(DirtyReducer.isDirty(currentLogicalHash: ContentHash.logicalHex("a"), lastSavedContentHash: nil))
    }
    func testOpenedFileIsCleanAndUndoBackToBaselineIsClean() {
        let base = ContentHash.logicalHex("hello")
        XCTAssertFalse(DirtyReducer.isDirty(currentLogicalHash: base, lastSavedContentHash: base))
        XCTAssertTrue(DirtyReducer.isDirty(currentLogicalHash: ContentHash.logicalHex("hello!"), lastSavedContentHash: base))
        XCTAssertFalse(DirtyReducer.isDirty(currentLogicalHash: ContentHash.logicalHex("hello"), lastSavedContentHash: base))
    }
    func testClassifier() {
        XCTAssertTrue(TextEditClassifier.affectsDirtyAndRecovery([.editedCharacters, .editedAttributes]))
        XCTAssertFalse(TextEditClassifier.affectsDirtyAndRecovery(.editedAttributes))
    }
}
