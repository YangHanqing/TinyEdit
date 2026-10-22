import XCTest
@testable import TinyEdit

final class TitlePathFormattingTests: XCTestCase {
    func testAbbreviateHome() {
        let cases: [(String, String, String)] = [
            ("/Users/me/src/app", "/Users/me", "~/src/app"),
            ("/Users/me", "/Users/me", "~"),
            ("/Users/me/", "/Users/me", "~"),
            ("/Users/me/src", "/Users/me/", "~/src"),
            ("/Users/melon/src", "/Users/me", "/Users/melon/src"),
            ("/tmp/a", "/Users/me", "/tmp/a"),
            ("/", "/Users/me", "/"),
            ("/Users/me", "/", "/Users/me"),
            ("/Users/me", "", "/Users/me"),
        ]
        for (directory, home, expected) in cases {
            XCTAssertEqual(TitlePathFormatting.abbreviate(directory: directory, home: home), expected,
                           "\(directory) home \(home)")
        }
    }

    func testDirectoryAndFilePath() {
        XCTAssertEqual(TitlePathFormatting.directory(ofFile: URL(fileURLWithPath: "/Users/me/src/a.txt")), "/Users/me/src")
        XCTAssertEqual(TitlePathFormatting.directory(ofFile: URL(fileURLWithPath: "/a.txt")), "/")
        XCTAssertEqual(TitlePathFormatting.filePath(directory: "/Users/me/src", filename: "a.txt"), "/Users/me/src/a.txt")
        XCTAssertEqual(TitlePathFormatting.filePath(directory: "/", filename: "a.txt"), "/a.txt")
    }

    func testUserHomeIsNotTheSandboxContainer() {
        XCTAssertFalse(TitlePathFormatting.userHome.contains("/Library/Containers/"), TitlePathFormatting.userHome)
        XCTAssertTrue(NSHomeDirectory().hasPrefix(TitlePathFormatting.userHome))
    }

    func testDirectoryPathRoundTripsAndOldManifestOmitsIt() throws {
        var buffer = EditorBuffer(title: "notes.txt")
        buffer.fileDisplayName = "notes.txt"
        buffer.directoryPath = "/Users/me/src"
        let data = try JSONEncoder().encode(BufferMetadata(buffer))
        let back = try JSONDecoder().decode(BufferMetadata.self, from: data)
        XCTAssertEqual(back.directoryPath, "/Users/me/src")
        XCTAssertEqual(back.makeBuffer()?.directoryPath, "/Users/me/src")

        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "directoryPath")
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(BufferMetadata.self, from: old)
        XCTAssertNil(decoded.directoryPath)
        XCTAssertEqual(decoded.makeBuffer()?.title, "notes.txt")
        XCTAssertNil(decoded.makeBuffer()?.directoryPath)
    }
}
