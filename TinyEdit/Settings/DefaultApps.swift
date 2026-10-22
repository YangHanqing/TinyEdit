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

/// Which app opens each `DefaultAppFormat`, read from Launch Services. TinyEdit cannot change it
/// itself: in the sandbox `NSWorkspace.setDefaultApplication` fails with permErr (-54), reported as
/// "the file couldn't be opened", on every macOS version. So the pane shows an example file of the
/// format in Finder, where Get Info ▸ Open With ▸ Change All makes the change.
@MainActor @Observable
final class DefaultAppModel {
    /// The default app per type identifier; a missing key means no app is set.
    private(set) var handlers: [String: URL] = [:]
    private(set) var lastError: String?

    let formats = DefaultAppFormat.all
    private let examples: URL

    init(examples: URL = AppPaths.root.appendingPathComponent("Default App Examples", isDirectory: true)) {
        self.examples = examples
    }

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

    /// An empty file of the format, created if needed. Change All in its Get Info applies to every
    /// file of the type, wherever it is.
    func exampleFile(for format: DefaultAppFormat) throws -> URL {
        // The first listed extension, whose system type the format is.
        let ext = format.extensions.split(separator: " ")[0].dropFirst()
        let url = examples.appendingPathComponent("Example").appendingPathExtension(String(ext))
        try FileManager.default.createDirectory(at: examples, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
        return url
    }

    func revealExample(for format: DefaultAppFormat) {
        lastError = nil
        do {
            NSWorkspace.shared.activateFileViewerSelecting([try exampleFile(for: format)])
        } catch {
            lastError = String(localized: "Couldn’t create the example file: \(error.localizedDescription)")
        }
    }
}
