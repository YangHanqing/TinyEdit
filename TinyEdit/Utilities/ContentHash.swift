import CryptoKit
import Foundation

enum ContentHash {
    static let emptyStringHex = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hash of the logical LF text as UTF-8, no BOM.
    static func logicalHex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }
}
