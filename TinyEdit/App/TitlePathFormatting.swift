import Foundation

/// Pure formatting for the title-bar path. The directory string is metadata captured when a file
/// URL is resolved; nothing here touches the bookmark or the disk.
enum TitlePathFormatting {
    /// Parent directory of a file URL. `/` for a file at the volume root. No trailing slash.
    static func directory(ofFile url: URL) -> String {
        let path = url.deletingLastPathComponent().path
        if path.isEmpty || path == "/" { return "/" }
        return stripTrailingSlash(path)
    }

    /// Absolute path of the file, for the tooltip. `directory` is a `directory(ofFile:)` result.
    static func filePath(directory: String, filename: String) -> String {
        let directory = stripTrailingSlash(directory)
        if directory == "/" { return "/" + filename }
        return directory + "/" + filename
    }

    /// The user's real home directory. Inside the App Sandbox both `NSHomeDirectory()` and
    /// `FileManager.homeDirectoryForCurrentUser` return the container, so read the password entry.
    static let userHome: String = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }()

    /// Replaces `home` with `~`. `home` must be the user home (`userHome`), not the sandbox container. A lookalike prefix
    /// (`/Users/melon` for home `/Users/me`) is left alone.
    static func abbreviate(directory: String, home: String) -> String {
        let directory = stripTrailingSlash(directory)
        let home = stripTrailingSlash(home)
        guard home.count > 1 else { return directory }
        if directory == home { return "~" }
        let prefix = home + "/"
        guard directory.hasPrefix(prefix) else { return directory }
        return "~/" + directory.dropFirst(prefix.count)
    }

    private static func stripTrailingSlash(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
