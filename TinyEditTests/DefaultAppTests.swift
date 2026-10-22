import UniformTypeIdentifiers
import XCTest
@testable import TinyEdit

/// Settings ▸ Default App lists only types Launch Services can assign, and TinyEdit declares
/// every one of them, so a request to become the default is never for a type it cannot open.
final class DefaultAppTests: XCTestCase {
    func testEveryFormatResolvesToADeclaredTextType() {
        let formats = DefaultAppFormat.all
        XCTAssertEqual(formats.count, 13, "a listed extension no longer has a system type")
        XCTAssertEqual(Set(formats.map(\.id)).count, formats.count)
        for format in formats {
            XCTAssertFalse(format.type.isDynamic, format.id)
            XCTAssertTrue(format.type.conforms(to: .text), format.id)
            XCTAssertTrue(format.extensions.hasPrefix("."), format.id)
        }
        XCTAssertEqual(formats.first?.type, .plainText)
    }

    func testInfoPlistClaimsEveryFormat() throws {
        let documentTypes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        let claimed = documentTypes
            .filter { $0["CFBundleTypeRole"] as? String == "Editor" }
            .flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
            .compactMap(UTType.init)
        for format in DefaultAppFormat.all {
            XCTAssertTrue(claimed.contains { format.type.conforms(to: $0) }, format.id)
        }
    }

    @MainActor
    func testRefreshReadsAHandlerForPlainText() {
        let model = DefaultAppModel()
        model.refresh()
        // Every Mac has at least TextEdit for plain text.
        XCTAssertNotNil(model.handlers[UTType.plainText.identifier])
        XCTAssertEqual(model.pendingFormats.count + model.formats.filter(model.opensWithTinyEdit).count, model.formats.count)
    }
}
