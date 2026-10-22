import SwiftUI
import ImageIO
import Observation

/// Relative references use the Markdown file, never the process's current working directory.
enum MarkdownImageSource: Equatable {
    case local(URL), remote(URL), unsaved, unsupported

    init(_ source: URL, document: URL?) {
        switch source.scheme?.lowercased() {
        case "http", "https": self = source.host == nil ? .unsupported : .remote(source)
        case "file": self = .local(source.standardizedFileURL)
        case nil:
            guard let document, document.isFileURL else { self = .unsaved; return }
            guard !source.relativeString.hasPrefix("//"),
                  let url = URL(string: source.relativeString, relativeTo: document)?.absoluteURL,
                  url.isFileURL else { self = .unsupported; return }
            self = .local(url.standardizedFileURL)
        default: self = .unsupported
        }
    }
}

@MainActor @Observable
final class MarkdownImageAccess {
    var generation = 0
    var authorizationMessage: String?
    @ObservationIgnored private let bookmarkFile: URL
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var scoped = false
    @ObservationIgnored private let cache = NSCache<NSURL, NSImage>()

    init(bookmarkFile: URL = AppPaths.root.appendingPathComponent("markdown-image-folders.json")) {
        self.bookmarkFile = bookmarkFile
        cache.countLimit = 24
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }
    func remember(_ image: NSImage, at url: URL) {
        cache.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * 4))
    }

    func chooseFolder(document: URL?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = document?.deletingLastPathComponent()
        panel.message = String(localized: "Choose the folder containing this document's images.")
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        authorize(selected, document: document)
    }

    /// Remember an explicit folder grant per saved document. Never infer a grant from a file path.
    func authorize(_ selected: URL, document: URL?) {
        reset()
        folder = selected
        scoped = selected.startAccessingSecurityScopedResource()
        guard let document else { return }
        do {
            let bookmark = try selected.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                     includingResourceValuesForKeys: nil, relativeTo: nil)
            var bookmarks = readBookmarks()
            bookmarks[document.standardizedFileURL.absoluteString] = bookmark
            try saveBookmarks(bookmarks)
        } catch {
            authorizationMessage = String(localized: "Folder access could not be saved. Allow it again after reopening.")
        }
    }

    func activate(document: URL?) {
        reset()
        guard let document else { return }
        let key = document.standardizedFileURL.absoluteString
        guard let bookmark = readBookmarks()[key] else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            folder = url
            scoped = url.startAccessingSecurityScopedResource()
            if stale {
                let fresh = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                 includingResourceValuesForKeys: nil, relativeTo: nil)
                var bookmarks = readBookmarks()
                bookmarks[key] = fresh
                try saveBookmarks(bookmarks)
            }
        } catch {
            authorizationMessage = String(localized: "Folder access expired. Allow the image folder again.")
        }
    }

    private func readBookmarks() -> [String: Data] {
        guard let data = try? Data(contentsOf: bookmarkFile),
              let bookmarks = try? JSONDecoder().decode([String: Data].self, from: data) else { return [:] }
        return bookmarks
    }

    private func saveBookmarks(_ bookmarks: [String: Data]) throws {
        try FileManager.default.createDirectory(at: bookmarkFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(bookmarks).write(to: bookmarkFile, options: .atomic)
    }

    func reset() {
        if let folder, scoped { folder.stopAccessingSecurityScopedResource() }
        folder = nil
        authorizationMessage = nil
        scoped = false
        cache.removeAllObjects()
        generation += 1
    }
}

/// Decode off the main actor, bounded both on disk and after decompression. Animated images show
/// their first frame. Loading an HTML document as an image cannot execute its contents.
enum MarkdownImageLoader {
    static func load(_ source: MarkdownImageSource) async throws -> CGImage {
        let data: Data
        switch source {
        case .local(let url):
            data = try await Task.detached(priority: .utility) {
                let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard size.isRegularFile == true, let bytes = size.fileSize, bytes <= RemoteImageLoader.maxBytes else {
                    throw ImagePreviewFailure.notImage
                }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let data = try file.read(upToCount: RemoteImageLoader.maxBytes + 1) ?? Data()
                guard data.count <= RemoteImageLoader.maxBytes else { throw ImagePreviewFailure.notImage }
                return data
            }.value
        case .remote(let url): data = try await RemoteImageLoader.load(url).data
        default: throw ImagePreviewFailure.notImage
        }
        try Task.checkCancellation()
        return try await Task.detached(priority: .utility) {
            guard data.count <= RemoteImageLoader.maxBytes,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw ImagePreviewFailure.notImage }
            return image
        }.value
    }
}

extension EnvironmentValues {
    @Entry var markdownDocumentURL: URL? = nil
    @Entry var markdownImageAccess: MarkdownImageAccess? = nil
    @Entry var markdownAvailableWidth: CGFloat = 600
}

struct MarkdownImageView: View {
    let reference: MarkdownImageReference
    @Environment(\.openURL) private var openURL
    @Environment(\.markdownDocumentURL) private var document
    @Environment(\.markdownImageAccess) private var access
    @Environment(\.markdownAvailableWidth) private var availableWidth
    @State private var image: NSImage?
    @State private var failure: String?
    @State private var retry = 0
    @State private var loading = false
    @State private var remoteConsent: String?

    private var source: MarkdownImageSource { MarkdownImageSource(reference.source, document: document) }
    private var alt: String {
        reference.alt == "\u{fffc}" ? reference.source.lastPathComponent : reference.alt
    }
    private var identity: String {
        "\(reference.source)|\(document?.absoluteString ?? "")|\(access?.generation ?? 0)"
    }

    private var requestedRemote: Bool { remoteConsent == identity }

    var body: some View {
        Group {
            if let image {
                let size = Self.fit(image.size, dimensions: reference.dimensions, available: availableWidth)
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .accessibilityLabel(Text(verbatim: alt))
                    .onTapGesture { if let link = reference.link { openURL(link) } }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label { Text(verbatim: alt.isEmpty ? reference.source.lastPathComponent : alt) }
                        icon: { Image(systemName: "photo") }
                    if loading { ProgressView().controlSize(.small) }
                    else if case .remote = source, !requestedRemote {
                        Button("Load Image") { remoteConsent = identity }
                    } else if case .unsaved = source {
                        Text("Save the document to resolve relative images.").font(.caption)
                    } else if let failure {
                        Text(failure).font(.caption)
                        Button("Retry") { retry += 1 }
                        if case .local = source {
                            Button("Allow Folder…") { access?.chooseFolder(document: document) }
                            if let message = access?.authorizationMessage { Text(message).font(.caption) }
                        }
                    }
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: min(availableWidth, 360), alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .task(id: identity + "|\(requestedRemote)|\(retry)") { await load() }
    }

    /// Width/height HTML hints are bounds; fit into the current column without stretching the image.
    static func fit(_ size: CGSize, dimensions: MarkdownImageDimensions, available: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 1, height: 1) }
        let desiredWidth = dimensions.width.map(CGFloat.init)
            ?? dimensions.height.map { size.width * CGFloat($0) / size.height } ?? size.width
        let width = min(max(1, available), desiredWidth)
        let height = CGFloat(dimensions.height ?? Int.max)
        let scale = min(width / size.width, height / size.height)
        return CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
    }

    @MainActor private func load() async {
        image = nil
        failure = nil
        loading = false
        let loadIdentity = identity
        if case .remote = source, !requestedRemote { return }
        if case .unsaved = source { return }
        let url: URL
        switch source {
        case .local(let value), .remote(let value): url = value
        default: failure = String(localized: "Unsupported image source"); return
        }
        if let cached = access?.cached(url) { image = cached; return }
        loading = true
        defer { loading = false }
        do {
            let pixels = try await MarkdownImageLoader.load(source)
            try Task.checkCancellation()
            let loaded = NSImage(cgImage: pixels, size: CGSize(width: pixels.width, height: pixels.height))
            guard identity == loadIdentity else { return }
            access?.remember(loaded, at: url)
            image = loaded
        } catch is CancellationError { }
        catch {
            if !Task.isCancelled, identity == loadIdentity {
                let code = (error as NSError).code
                if case .local = source, (error as NSError).domain == NSCocoaErrorDomain,
                   [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(code) {
                    failure = String(localized: "Image file not found. Check the relative path.")
                } else {
                    failure = String(localized: "Image unavailable")
                }
            }
        }
    }
}
