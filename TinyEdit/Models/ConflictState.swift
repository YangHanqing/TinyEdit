import Foundation

enum ConflictState: String, Codable, Sendable {
    case none, external, missing
}

/// The changed disk bytes an `.external` conflict is about, and whether the user chose Keep My Version
/// over them. Keeping hides the banner until the file changes again. Session-only.
struct ExternalChange: Equatable, Sendable {
    /// Raw hash of the changed bytes. Nil until they are read (a conflict restored from the session, or
    /// one raised by a refused save); a kept change then takes the first hash read.
    var hash: String?
    var kept = false
}
