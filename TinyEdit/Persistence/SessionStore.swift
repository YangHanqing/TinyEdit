import Foundation

enum SessionDecodeResult: Equatable {
    case loaded(SessionFile)
    case noSession        // fresh install: no manifest on disk
    case unreadable       // caller quarantines and scans snapshots
}

/// Reads and writes Session/session.json. `load()` never writes.
final class SessionStore: @unchecked Sendable {
    let root: URL
    var sessionDirectory: URL { root.appendingPathComponent("Session", isDirectory: true) }
    var manifestURL: URL { sessionDirectory.appendingPathComponent("session.json") }

    init(root: URL) { self.root = root }

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// `^[0-9A-Fa-f-]{36}\.snapshot$`. A recoveryFile is a filename, never a path.
    static func validateRecoveryFileName(_ name: String) -> Bool {
        name.range(of: #"^[0-9A-Fa-f-]{36}\.snapshot$"#, options: .regularExpression) != nil
    }

    func load() -> SessionDecodeResult {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return .noSession }
        do {
            let data = try Data(contentsOf: manifestURL)
            var file = try Self.makeDecoder().decode(SessionFile.self, from: data)
            guard file.schemaVersion == SessionFile.currentSchemaVersion else { return .unreadable }
            if file.repairTabOrder() { Log.session.info("tabOrder repaired on load") }
            return .loaded(file)
        } catch {
            Log.session.error("session.json unreadable: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            return .unreadable
        }
    }

    func save(_ file: SessionFile) throws {
        var file = file
        file.closedTabs = Array(file.closedTabs.prefix(EditorSession.maxClosedTabs))
        file.tombstones = Array(file.tombstones.suffix(EditorSession.maxTombstones))
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try AtomicFileWriter.write(try Self.makeEncoder().encode(file), to: manifestURL)
    }

    /// Renames session.json aside. Never touches Buffers/.
    @discardableResult
    func quarantineCorruptManifest(now: Date = Date()) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let dest = sessionDirectory.appendingPathComponent("session.json.rejected-\(stamp)")
        try FileManager.default.moveItem(at: manifestURL, to: dest)
        return dest
    }
}
