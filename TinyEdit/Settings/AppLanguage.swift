import AppKit

/// The language the user picked in Settings. This is not the language the running
/// process is showing: `AppleLanguages` is read at the next launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case ja
    case ko
    case de
    case fr
    case es

    static let storageKey = "tinyedit.language"

    var id: String { rawValue }

    /// Endonym, except System, which follows the interface language already on screen.
    var label: String {
        switch self {
        case .system: String(localized: "System")
        case .en: "English"
        case .zhHans: "简体中文"
        case .zhHant: "繁體中文"
        case .ja: "日本語"
        case .ko: "한국어"
        case .de: "Deutsch"
        case .fr: "Français"
        case .es: "Español"
        }
    }

    static var stored: AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let language = AppLanguage(rawValue: raw) else { return .system }
        return language
    }

    /// Writes the picker choice and the launch override. The running UI does not switch.
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(rawValue, forKey: Self.storageKey)
        if self == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// Saves the choice, then offers to quit. The app cannot relaunch itself: it is sandboxed and
    /// `LSMultipleInstancesProhibited` refuses a second instance, so the user reopens it. Quitting goes
    /// through `NSApp.terminate`, so the recovery flush runs and tabs and unsaved text come back.
    @MainActor
    static func commit(_ language: AppLanguage) {
        guard language != stored else { return }
        language.save()
        let alert = NSAlert()
        alert.messageText = String(localized: "Quit TinyEdit to use the new language?")
        alert.informativeText = String(localized: "The new language takes effect the next time you open TinyEdit. Your tabs and unsaved text are kept.")
        alert.addButton(withTitle: String(localized: "Quit Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        alert.buttons[1].keyEquivalent = "\u{1b}"
        if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
    }
}
