import AppKit

/// Immutable snapshot of an explicit user action; never updated on each keystroke.
struct TranslationInput: Identifiable {
    let id = UUID()
    let bufferID: UUID
    let generation: UInt64
    let range: NSRange
    let text: String
    let wholeDocument: Bool
}

extension AppState {
    func presentTranslation(wholeDocument: Bool = false) {
        guard let store = activeStore else { return }
        let range = wholeDocument ? NSRange(location: 0, length: store.length) : host.textView.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= store.length else {
            showToast(String(localized: "Select text to translate."))
            return
        }
        guard range.length <= TranslationPlan.inputLimit else {
            showToast(TranslationFailure.tooLong.localizedDescription, error: true)
            return
        }
        let text = store.textStorage.mutableString.substring(with: range)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        translationInput = TranslationInput(bufferID: store.id, generation: store.generation,
                                            range: range, text: text, wholeDocument: wholeDocument)
    }

    @discardableResult
    func replaceTranslation(_ input: TranslationInput, with text: String) -> Bool {
        guard session.selectedBufferID == input.bufferID, let store = stores[input.bufferID],
              store.generation == input.generation, NSMaxRange(input.range) <= store.length,
              store.textStorage.mutableString.substring(with: input.range) == input.text else {
            showToast(String(localized: "The original text changed. Copy the translation or open it in a new tab."), error: true)
            return false
        }
        host.activate(store, settings: settings)
        replace(input.range, with: text, select: true)
        return true
    }

    /// False when no tab was added (at the tab limit); the text is then not inserted anywhere.
    @discardableResult
    func openTranslationTab(_ text: String) -> Bool {
        guard launchGateOpen, newTab() else { return false }
        // Reuse the editor edit pipeline so dirty state, recovery, highlighting and undo stay consistent.
        if let store = activeStore { host.activate(store, settings: settings) }
        replace(NSRange(location: 0, length: 0), with: text, select: false)
        activeBufferChanged()
        flushImmediately()
        return true
    }
}
