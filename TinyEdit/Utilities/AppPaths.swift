import Foundation

enum AppPaths {
    /// `~/Library/Application Support/TinyEdit` (inside the container when sandboxed).
    /// Unit tests get a throwaway root so they never touch a real session.
    static var root: URL {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("TinyEdit-test-host", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TinyEdit", isDirectory: true)
    }
}
