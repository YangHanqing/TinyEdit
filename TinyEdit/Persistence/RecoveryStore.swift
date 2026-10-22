import Foundation

enum RecoveryError: Error { case invalidFileName, notUTF8 }

/// Snapshot files: Buffers/<UUID>.snapshot, UTF-8, LF, no BOM.
final class RecoveryStore: @unchecked Sendable {
    let root: URL
    var buffersDirectory: URL { root.appendingPathComponent("Buffers", isDirectory: true) }

    init(root: URL) { self.root = root }

    private func url(for recoveryFile: String) throws -> URL {
        guard SessionStore.validateRecoveryFileName(recoveryFile) else { throw RecoveryError.invalidFileName }
        return buffersDirectory.appendingPathComponent(recoveryFile)
    }

    func writeSnapshot(id: UUID, logicalLF: String) throws {
        try FileManager.default.createDirectory(at: buffersDirectory, withIntermediateDirectories: true)
        try AtomicFileWriter.write(Data(logicalLF.utf8), to: url(for: "\(id.uuidString).snapshot"))
    }

    func readSnapshot(recoveryFile: String) throws -> String {
        let data = try Data(contentsOf: url(for: recoveryFile))
        guard let s = String(data: data, encoding: .utf8) else { throw RecoveryError.notUTF8 }
        return s
    }

    func deleteSnapshot(recoveryFile: String) throws {
        try FileManager.default.removeItem(at: url(for: recoveryFile))
    }

    /// Ids of every validly named snapshot file, sorted by filename. Does not read contents.
    func snapshotIDs() -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: buffersDirectory.path)) ?? []
        return names.sorted().compactMap { name in
            guard SessionStore.validateRecoveryFileName(name) else { return nil }
            return UUID(uuidString: String(name.dropLast(".snapshot".count)))
        }
    }

    /// Valid-name, valid-UTF-8 snapshots, sorted by filename. Skips the rest and never deletes them.
    func validSnapshotFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: buffersDirectory.path)) ?? []
        return names.sorted().compactMap { name in
            guard SessionStore.validateRecoveryFileName(name) else { return nil }
            let u = buffersDirectory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: u), String(data: data, encoding: .utf8) != nil else {
                Log.recovery.error("snapshot skipped (not UTF-8 or unreadable), left on disk")
                return nil
            }
            return u
        }
    }
}
