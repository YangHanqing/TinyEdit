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
                for unit in try stringUnits(loc, "\(lang) \(key)") {
                    XCTAssertEqual(unit["state"] as? String, "translated", "\(lang) \(key)")
                    let value = try XCTUnwrap(unit["value"] as? String, "\(lang) \(key)")
                    XCTAssertEqual(specifiers(value), expected, "\(lang) placeholders for \(key)")
                }
            }
        }
        XCTAssertGreaterThan(translated, 50)
    }

    /// A plain translation, or every form of a plural one (which must have `other`).
    private func stringUnits(_ loc: [String: Any], _ label: String) throws -> [[String: Any]] {
        if let unit = loc["stringUnit"] as? [String: Any] { return [unit] }
        let variations = try XCTUnwrap(loc["variations"] as? [String: Any], label)
        let forms = try XCTUnwrap(variations["plural"] as? [String: Any], label)
        XCTAssertNotNil(forms["other"], "\(label) has no other form")
        return try forms.values.map { form in
            try XCTUnwrap((form as? [String: Any])?["stringUnit"] as? [String: Any], label)
        }
    }
}
