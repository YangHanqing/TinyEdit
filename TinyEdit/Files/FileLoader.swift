import Foundation

struct LoadedFile: Sendable {
    var logicalLF: String
    var encoding: TextEncoding
    var lineEnding: LineEnding
    var logicalHash: String   // SHA-256 of logical LF UTF-8, no BOM
    var rawHash: String       // SHA-256 of the raw bytes on disk
    var byteSize: Int
    var modificationDate: Date?
    var posixPermissions: Int?
}

enum FileOpenError: Error, Equatable {
    case couldNotOpenFile
    case fileTooLarge
}

enum FileLoader {
    static let maxOpenBytes = 67_108_864

    enum Decoding: Sendable {
        /// Open: BOM, UTF-8, then GB18030.
        case detect
        /// Reload: the buffer's encoding if the bytes decode as it, otherwise detect. A GB18030 file
        /// whose bytes also happen to be valid UTF-8 stays GB18030.
        case prefer(TextEncoding)
        /// Reopen with Encoding: that encoding or fail.
        case force(TextEncoding)
    }

    /// Blocking: call off the main thread.
    static func load(from url: URL, decoding: Decoding = .detect) throws -> LoadedFile {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if size > maxOpenBytes { throw FileOpenError.fileTooLarge }

        var data: Data?
        var coordError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            data = try? Data(contentsOf: u)
        }
        guard let data, coordError == nil else { throw FileOpenError.couldNotOpenFile }
        if data.count > maxOpenBytes { throw FileOpenError.fileTooLarge }
        return try make(from: data, decoding: decoding,
                        modificationDate: attrs?[.modificationDate] as? Date,
                        permissions: (attrs?[.posixPermissions] as? NSNumber)?.intValue)
    }

    /// Pure decode step, split out so tests need no files.
    static func make(from data: Data, decoding: Decoding = .detect,
                     modificationDate: Date? = nil, permissions: Int? = nil) throws -> LoadedFile {
        let result: (text: String, encoding: TextEncoding)?
        switch decoding {
        case .detect: result = try? TextEncoding.decode(data)
        case .prefer(let e): result = (try? TextEncoding.decode(data, as: e)) ?? (try? TextEncoding.decode(data))
        case .force(let e): result = try? TextEncoding.decode(data, as: e)
        }
        guard let (decoded, encoding) = result else { throw FileOpenError.couldNotOpenFile }
        let ending = LineEnding.detect(decoded)
        let logical = LineEnding.normalizeToLF(decoded)
        return LoadedFile(logicalLF: logical, encoding: encoding, lineEnding: ending,
                          logicalHash: ContentHash.logicalHex(logical),
                          rawHash: ContentHash.sha256Hex(data),
                          byteSize: data.count, modificationDate: modificationDate, posixPermissions: permissions)
    }
}
