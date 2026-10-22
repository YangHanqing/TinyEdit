import Foundation

enum FileSaveError: Error, Equatable {
    case couldNotSaveFile
    case externalChange
}

struct SavedFileStats: Sendable {
    var rawHash: String
    var logicalHash: String
    var byteSize: Int
    var modificationDate: Date
    var posixPermissions: Int
    var executableBitPreserved: Bool
}

/// The only code that writes user files. Never `Data.write(to:)` on the user URL.
enum FileSaver {
    /// Blocking: call off the main thread.
    static func save(logicalLF: String,
                     to url: URL,
                     encoding: TextEncoding,
                     lineEnding: LineEnding,
                     acknowledgedDiskHash: String?,
                     overwriteConfirmed: Bool,
                     presenter: NSFilePresenter?) throws -> SavedFileStats {
        let fm = FileManager.default
        guard let payload = try? encoding.encode(LineEnding.apply(logicalLF, ending: lineEnding)) else {
            throw FileSaveError.couldNotSaveFile
        }
        let payloadHash = ContentHash.sha256Hex(payload)
        let logicalHash = ContentHash.logicalHex(logicalLF)

        // Previous mode and creation date, best effort. A miss never fails the save.
        let previous = try? fm.attributesOfItem(atPath: url.path)
        let previousMode = (previous?[.posixPermissions] as? NSNumber)?.intValue
        let previousCreation = previous?[.creationDate] as? Date

        // Temp lives in the app container: a file bookmark does not grant sibling create.
        let tmp = fm.temporaryDirectory.appendingPathComponent("tinyedit-save-\(UUID().uuidString).tmp")
        guard (try? payload.write(to: tmp)) != nil else { throw FileSaveError.couldNotSaveFile }
        if let fh = try? FileHandle(forWritingTo: tmp) {
            try? fh.synchronize()
            try? fh.close()
        }
        defer { try? fm.removeItem(at: tmp) }

        var failure: Error?
        var coordError: NSError?
        NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: url, options: .forReplacing,
                                                               error: &coordError) { dest in
            do {
                // Authoritative check, inside the coordinator, immediately before bytes change.
                let exists = fm.fileExists(atPath: dest.path)
                if exists {
                    let rawNow = ContentHash.sha256Hex((try? Data(contentsOf: dest)) ?? Data())
                    if rawNow == payloadHash {
                        return // identical bytes already in place; acknowledge only
                    }
                    if rawNow != acknowledgedDiskHash && !overwriteConfirmed {
                        throw FileSaveError.externalChange
                    }
                }
                try install(tmp: tmp, payload: payload, at: dest, exists: exists)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        if coordError != nil { throw FileSaveError.couldNotSaveFile }

        // Restore mode and creation date best effort.
        var attrs: [FileAttributeKey: Any] = [:]
        if let previousMode { attrs[.posixPermissions] = previousMode }
        if let previousCreation { attrs[.creationDate] = previousCreation }
        if !attrs.isEmpty { try? fm.setAttributes(attrs, ofItemAtPath: url.path) }

        guard let now = try? fm.attributesOfItem(atPath: url.path) else { throw FileSaveError.couldNotSaveFile }
        let mode = (now[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let hadExec = (previousMode ?? 0) & 0o111 != 0
        return SavedFileStats(rawHash: payloadHash, logicalHash: logicalHash, byteSize: payload.count,
                              modificationDate: (now[.modificationDate] as? Date) ?? Date(),
                              posixPermissions: mode,
                              executableBitPreserved: !hadExec || (mode & 0o111) != 0)
    }

    /// Replace via the container temp. If the sandbox grants the file but not its directory and the
    /// replace is refused, fall back to an in-place write, which keeps inode, mode, xattrs and ACLs.
    /// Atomicity across volumes is best effort: `replaceItemAt` may copy.
    private static func install(tmp: URL, payload: Data, at dest: URL, exists: Bool) throws {
        let fm = FileManager.default
        do {
            if exists {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.copyItem(at: tmp, to: dest)
            }
            return
        } catch {
            Log.files.error("replace failed (\((error as NSError).domain, privacy: .public) \((error as NSError).code)); trying in-place write")
        }
        do {
            if !exists { guard fm.createFile(atPath: dest.path, contents: nil) else { throw FileSaveError.couldNotSaveFile } }
            let fh = try FileHandle(forWritingTo: dest)
            defer { try? fh.close() }
            try fh.truncate(atOffset: 0)
            try fh.write(contentsOf: payload)
            try fh.synchronize()
        } catch {
            throw FileSaveError.couldNotSaveFile
        }
    }
}
