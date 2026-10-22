import OSLog

/// Never log document text, find queries, full paths, bookmark data, or hashes.
enum Log {
    private static let subsystem = "cn.hqyang.tinyedit"
    static let session = Logger(subsystem: subsystem, category: "session")
    static let recovery = Logger(subsystem: subsystem, category: "recovery")
    static let files = Logger(subsystem: subsystem, category: "files")
    static let editor = Logger(subsystem: subsystem, category: "editor")
}
