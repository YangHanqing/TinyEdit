import Foundation

enum ImagePreviewFailure: Error, Equatable {
    case request(CurlFailure)
    case status(Int)
    case notImage
}

/// Downloads a picture for the JSON value preview, only when the user clicks Preview. Same ephemeral
/// configuration as curl requests (no cookies, cache or credentials kept); redirects are followed, as a
/// browser would for an image. Text and HTML answers stop early, and the body stops past 64 MB.
enum RemoteImageLoader {
    static let maxBytes = FileLoader.maxOpenBytes

    /// Throws `CancellationError` when the task is cancelled, otherwise `ImagePreviewFailure`.
    static func load(_ url: URL, configuration: URLSessionConfiguration = CurlRunner.makeConfiguration())
        async throws -> (data: Data, mimeType: String?) {
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ImagePreviewFailure.request(.other) }
            guard (200..<300).contains(http.statusCode) else { throw ImagePreviewFailure.status(http.statusCode) }
            let mime = http.mimeType?.lowercased()
            if let mime, mime.hasPrefix("text/") || mime.contains("json") || mime.contains("javascript") {
                throw ImagePreviewFailure.notImage
            }
            if http.expectedContentLength > Int64(maxBytes) { throw ImagePreviewFailure.request(.tooLarge) }
            var body: [UInt8] = []
            if http.expectedContentLength > 0 { body.reserveCapacity(Int(http.expectedContentLength)) }
            for try await byte in bytes {
                body.append(byte)
                if body.count > maxBytes { throw ImagePreviewFailure.request(.tooLarge) }
            }
            guard !body.isEmpty else { throw ImagePreviewFailure.notImage }
            return (Data(body), mime)
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw ImagePreviewFailure.request(.network(error.code))
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as ImagePreviewFailure {
            throw failure
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ImagePreviewFailure.request(.other)
        }
    }
}
