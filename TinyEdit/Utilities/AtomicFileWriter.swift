import Foundation

/// Atomic same-directory write for recovery snapshots and session.json ONLY.
/// User files go through FileSaver (coordinated replace), never through here.
enum AtomicFileWriter {
    static func write(_ data: Data, to destination: URL) throws {
        let fm = FileManager.default
        let dir = destination.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: tmp)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: destination)
            }
            fsyncDirectory(dir)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    private static func fsyncDirectory(_ dir: URL) {
        let fd = open(dir.path, O_RDONLY)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }
}
