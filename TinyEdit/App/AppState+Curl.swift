import AppKit

/// A curl request in flight for one buffer.
struct CurlJob {
    var token: UInt64
    var task: Task<Void, Never>
}

/// The text a curl command was sent from, without the blanks around it. Replace puts the response there.
struct CurlSource: Equatable {
    var range: NSRange
    var text: String
}

extension AppState {
    /// Characters of a text response shown on the card; Copy, Replace and Open in New Tab use all of it.
    nonisolated static let curlPreviewLimit = 2_000

    /// Send on the card a pasted curl command brought up.
    func sendPastedCurl() {
        guard let id = session.selectedBufferID, let offer = session.buffers[id]?.pasteSuggestion?.curl else { return }
        dismissPasteSuggestion()
        curlSources[id] = stores[id].flatMap { Self.curlSource(offer.range, in: $0.textStorage.mutableString) }
        startCurl(offer.command, for: id)
    }

    /// Tools ▸ Send curl Request: the selection, else the command the caret is in.
    func sendCurlAtCursor() {
        guard let id = session.selectedBufferID, let store = stores[id] else { return }
        let ns = store.textStorage.mutableString
        let sel = host.textView.selectedRange()
        let range = sel.length > 0 ? sel : CurlCommand.commandRange(around: sel.location, in: ns)
        guard let range, NSMaxRange(range) <= ns.length,
              let command = CurlCommand.parse(ns.substring(with: range)) else {
            return showToast(String(localized: "No curl command at the cursor"), error: true)
        }
        if let option = command.unsupported {
            return showToast(String(localized: "Can't send: \(option) is not supported"), error: true)
        }
        if session.buffers[id]?.pasteSuggestion?.curl != nil { dismissPasteSuggestion() }
        curlSources[id] = Self.curlSource(range, in: ns)
        startCurl(command, for: id)
    }

    /// Send Again on a finished or failed card.
    func resendCurl() {
        guard let id = session.selectedBufferID, let command = curlCommands[id] else { return }
        startCurl(command, for: id)
    }

    /// Cancel while sending, or close the card.
    func dismissCurl(_ id: UUID? = nil) {
        guard let id = id ?? session.selectedBufferID else { return }
        clearCurl(id)
    }

    /// Escape in the text view. False when there is no curl card, so the paste card gets the key.
    func dismissCurlFromEscape() -> Bool {
        guard let id = session.selectedBufferID, session.buffers[id]?.curlRun != nil else { return false }
        clearCurl(id)
        return true
    }

    func copyCurlResponse() {
        guard let id = session.selectedBufferID, let text = curlBodies[id] else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showToast(String(localized: "Copied"))
    }

    /// The response text in a new Untitled tab, named after the request and set to the response's language.
    func openCurlResponse() {
        guard launchGateOpen, let id = session.selectedBufferID, let text = curlBodies[id],
              case .finished(let summary, let result) = session.buffers[id]?.curlRun,
              ensureRoomForTab() else { return }   // checked first: the card keeps the response
        clearCurl(id)
        openTranslationTab(text)
        guard let newID = session.selectedBufferID, newID != id else { return }
        if case .text(_, let language?) = result.body { setLanguage(language) }
        renameTab(newID, to: Self.curlTabTitle(summary, status: result.status))
    }

    /// Replaces the command the request was sent from with the response text, as one undo group. Where the
    /// command was is checked first; if it moved, its text is looked for elsewhere in the tab. A response that
    /// is then the whole tab sets the tab's language.
    func replaceCurlCommandWithResponse() {
        guard let id = session.selectedBufferID, let store = stores[id], let text = curlBodies[id],
              case .finished(_, let result) = session.buffers[id]?.curlRun else { return }
        let ns = store.textStorage.mutableString
        guard let range = curlSources[id].flatMap({ Self.locate($0, in: ns) }) else {
            return showToast(String(localized: "The curl command is no longer in the tab"), error: true)
        }
        clearCurl(id)
        let fillsTab = Self.isBlank(ns, outside: range)
        replace(range, with: text, select: false)
        if fillsTab, case .text(_, let language?) = result.body, session.buffers[id]?.language != language {
            setLanguage(language)
        }
    }

    nonisolated static func curlSource(_ range: NSRange, in text: NSString) -> CurlSource? {
        guard NSMaxRange(range) <= text.length else { return nil }
        let whole = text.substring(with: range) as NSString
        let trimmed = whole.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let offset = whole.range(of: trimmed).location
        return CurlSource(range: NSRange(location: range.location + offset, length: (trimmed as NSString).length), text: trimmed)
    }

    /// The source range when it still holds the command, else the command's text nearest to it.
    nonisolated static func locate(_ source: CurlSource, in text: NSString) -> NSRange? {
        if NSMaxRange(source.range) <= text.length, text.substring(with: source.range) == source.text {
            return source.range
        }
        var best: NSRange?
        var search = NSRange(location: 0, length: text.length)
        while search.length > 0 {
            let found = text.range(of: source.text, options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            if best.map({ abs($0.location - source.range.location) > abs(found.location - source.range.location) }) ?? true {
                best = found
            }
            search = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
        }
        return best
    }

    static func curlTabTitle(_ summary: CurlSummary, status: Int) -> String {
        let path = summary.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        return "\(summary.method) \(path) · \(status)"
    }

    // MARK: Running

    /// Off the main thread; a newer request from the same tab replaces this one. Observed state is written when the
    /// card appears and when the result lands.
    private func startCurl(_ command: CurlCommand, for id: UUID) {
        curlJobs[id]?.task.cancel()
        curlToken &+= 1
        let token = curlToken
        let summary = CurlSummary(command)
        let task = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { () -> Result<CurlResponse, Error> in
                do { return .success(try await CurlRunner.send(command)) } catch { return .failure(error) }
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let self else { return }
            let shown = await Task.detached(priority: .userInitiated) { Self.present(result) }.value
            guard !Task.isCancelled else { return }
            self.finishCurl(id, token: token, summary: summary, shown: shown)
        }
        curlJobs[id] = CurlJob(token: token, task: task)
        curlCommands[id] = command
        curlBodies[id] = nil
        session.buffers[id]?.curlRun = .sending(summary, started: Date())
    }

    private func finishCurl(_ id: UUID, token: UInt64, summary: CurlSummary, shown: Result<(CurlResult, String?), CurlShownFailure>) {
        guard let job = curlJobs[id], job.token == token, session.buffers[id] != nil else { return }
        curlJobs[id] = nil
        switch shown {
        case .success(let (result, text)):
            curlBodies[id] = text
            session.buffers[id]?.curlRun = .finished(summary, result)
        case .failure(.cancelled):
            session.buffers[id]?.curlRun = nil
        case .failure(let failure):
            session.buffers[id]?.curlRun = .failed(summary, message: failure.message)
        }
    }

    private func clearCurl(_ id: UUID) {
        curlJobs[id]?.task.cancel()
        curlJobs[id] = nil
        curlBodies[id] = nil
        curlCommands[id] = nil
        curlSources[id] = nil
        if session.buffers[id]?.curlRun != nil { session.buffers[id]?.curlRun = nil }
    }

    /// Decodes the body (pretty JSON, charset, binary) off the main thread.
    nonisolated private static func present(_ result: Result<CurlResponse, Error>) -> Result<(CurlResult, String?), CurlShownFailure> {
        switch result {
        case .failure(let error as CurlFailure): return .failure(.failed(error))
        case .failure(is CancellationError): return .failure(.cancelled)
        case .failure: return .failure(.failed(.other))
        case .success(let response):
            let body: CurlResultBody
            var text: String?
            switch CurlRunner.body(of: response) {
            case .empty: body = .empty
            case .binary(let mime): body = .binary(mimeType: mime)
            case .text(let full, let language):
                text = full
                let preview = full.count > curlPreviewLimit ? String(full.prefix(curlPreviewLimit)) + "…" : full
                body = .text(preview: preview, language: language)
            }
            let result = CurlResult(status: response.status, reason: CurlRunner.reason(for: response.status),
                                    elapsed: response.elapsed, byteCount: response.body.count,
                                    headers: response.headers, body: body)
            return .success((result, text))
        }
    }
}

/// Why a request produced no response, as the card says it.
enum CurlShownFailure: Error {
    case cancelled
    case failed(CurlFailure)

    var message: String {
        guard case .failed(let failure) = self else { return "" }
        switch failure {
        case .tooLarge: return String(localized: "The response is larger than 64 MB.")
        case .other: return String(localized: "The request could not be completed.")
        case .network(let code):
            switch code {
            case .timedOut: return String(localized: "The server did not respond in time.")
            case .cannotFindHost, .dnsLookupFailed: return String(localized: "Could not find the server.")
            case .cannotConnectToHost: return String(localized: "Could not connect to the server.")
            case .notConnectedToInternet: return String(localized: "This Mac is not connected to the internet.")
            case .networkConnectionLost: return String(localized: "The connection was lost.")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
                 .clientCertificateRequired:
                return String(localized: "Could not make a secure connection. The server's certificate may be invalid.")
            case .appTransportSecurityRequiresSecureConnection:
                return String(localized: "Plain HTTP is sent only to local addresses. Use https:// for this server.")
            case .httpTooManyRedirects: return String(localized: "The server redirected too many times.")
            case .badURL, .unsupportedURL: return String(localized: "The URL is not valid.")
            case .dataLengthExceedsMaximum: return String(localized: "The response is larger than 64 MB.")
            default: return String(localized: "The request could not be completed.")
            }
        }
    }
}
