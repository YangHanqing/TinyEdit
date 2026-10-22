import AppKit
import Observation
import UniformTypeIdentifiers

/// A text format that Settings ▸ Default App offers to open with TinyEdit.
struct DefaultAppFormat: Identifiable, Sendable {
    let type: UTType
    let name: String
    /// Shown under the name, e.g. ".yaml .yml".
    let extensions: String

    var id: String { type.identifier }

    /// Formats a text editor is a sensible default for. Web formats (HTML, CSS, JavaScript) are left
    /// out because their usual default is a browser. Each type comes from the system's own
    /// declaration for the first extension; one the system does not declare (a dynamic type) cannot
    /// be given a default app and is dropped.
    static let all: [DefaultAppFormat] = [
        (String(localized: "Plain Text"), "txt"),
        (EditorLanguage.markdown.statusLabel, "md markdown"),
        (EditorLanguage.json.statusLabel, "json"),
        (EditorLanguage.yaml.statusLabel, "yaml yml"),
        (EditorLanguage.toml.statusLabel, "toml"),
        (EditorLanguage.xml.statusLabel, "xml"),
        ("INI", "ini"),
        (String(localized: "Log File"), "log"),
        ("CSV", "csv"),
        (EditorLanguage.shell.statusLabel, "sh"),
        (EditorLanguage.python.statusLabel, "py"),
        (EditorLanguage.sql.statusLabel, "sql"),
        (EditorLanguage.diff.statusLabel, "diff patch"),
    ].compactMap { name, exts in
        let list = exts.split(separator: " ").map(String.init)
        guard let first = list.first, let type = UTType(filenameExtension: first), !type.isDynamic else { return nil }
        return DefaultAppFormat(type: type, name: name, extensions: list.map { "." + $0 }.joined(separator: " "))
    }
}

/// Which app opens each `DefaultAppFormat`, read from Launch Services, and the requests that make
/// TinyEdit the default. macOS asks the user to confirm each change.
@MainActor @Observable
final class DefaultAppModel {
    /// The default app per type identifier; a missing key means no app is set.
    private(set) var handlers: [String: URL] = [:]
    private(set) var isChanging = false
    private(set) var lastError: String?

    let formats = DefaultAppFormat.all

    func refresh() {
        var found: [String: URL] = [:]
        for format in formats {
            found[format.id] = NSWorkspace.shared.urlForApplication(toOpen: format.type)
        }
        if found != handlers { handlers = found }
    }

    /// Any copy of TinyEdit with this bundle identifier counts, wherever it is installed.
    func opensWithTinyEdit(_ format: DefaultAppFormat) -> Bool {
        guard let url = handlers[format.id] else { return false }
        return Bundle(url: url)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    var pendingFormats: [DefaultAppFormat] { formats.filter { !opensWithTinyEdit($0) } }

    /// Asks for one format at a time and stops at the first one that is refused, so declining
    /// the first confirmation does not bring up a dozen more.
    func makeDefault(_ targets: [DefaultAppFormat]) async {
        guard !isChanging, !targets.isEmpty else { return }
        isChanging = true
        lastError = nil
        defer {
            isChanging = false
            refresh()
        }
        for format in targets {
            do {
                try await Self.setDefault(Bundle.main.bundleURL, for: format.type)
            } catch {
                if !Self.isUserCancel(error) {
                    lastError = String(localized: "Couldn’t make TinyEdit the default for \(format.name): \(error.localizedDescription)")
                }
                return
            }
            refresh()
        }
    }

    private static func setDefault(_ app: URL, for type: UTType) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func isUserCancel(_ error: Error) -> Bool {
        let ns = error as NSError
        return (ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError)
            || (ns.domain == NSOSStatusErrorDomain && ns.code == Int(userCanceledErr))
    }
}
