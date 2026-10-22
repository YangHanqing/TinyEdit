import XCTest

/// The string catalog is complete: every translatable key has a translation in each
/// supported language, and format placeholders match the English source.
final class StringCatalogTests: XCTestCase {
    func testCatalogTranslationsMatchEnglishPlaceholders() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("TinyEdit/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try XCTUnwrap(json?["strings"] as? [String: Any])
        let languages = ["zh-Hans", "zh-Hant", "ja", "ko", "de", "fr", "es"]
        let placeholder = try NSRegularExpression(
            pattern: #"%(?!%)(?:\d+\$)?[#0\-+\s]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|z|t|j|L)?[@a-zA-Z]"#)

        func specifiers(_ s: String) -> [String] {
            let range = NSRange(s.startIndex..., in: s)
            return placeholder.matches(in: s, range: range).compactMap {
                Range($0.range, in: s).map { String(s[$0]) }
            }.sorted()
        }

        var translated = 0
        for (key, raw) in strings {
            let entry = try XCTUnwrap(raw as? [String: Any], "\(key) is not an object")
            if (entry["shouldTranslate"] as? Bool) == false { continue }
            translated += 1
            let locs = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            let english: String
            if let en = locs["en"] as? [String: Any],
               let unit = en["stringUnit"] as? [String: Any],
               let value = unit["value"] as? String {
                english = value
            } else {
                english = key
            }
            let expected = specifiers(english)
            for lang in languages {
                let loc = try XCTUnwrap(locs[lang] as? [String: Any], "\(lang) missing for \(key)")
                let unit = try XCTUnwrap(loc["stringUnit"] as? [String: Any], "\(lang) \(key)")
                XCTAssertEqual(unit["state"] as? String, "translated", "\(lang) \(key)")
                let value = try XCTUnwrap(unit["value"] as? String, "\(lang) \(key)")
                XCTAssertEqual(specifiers(value), expected, "\(lang) placeholders for \(key)")
            }
        }
        XCTAssertGreaterThan(translated, 50)
    }
}
