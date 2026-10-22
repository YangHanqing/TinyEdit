import Foundation

/// A color written in a JSON string (`#RRGGBB`, `rgb()`, `hsl()`), in sRGB components from 0 to 1.
struct JSONColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
}

/// What is special about a JSON member's value, for the status bar: a link to open, query parameters
/// to read, a picture to preview, encodings to decode, a Unix time or a color to show. Pure; found
/// with the member (`JSONCaretInfo`), so it is written only when the member or its value changes.
struct JSONValueInsight: Equatable, Sendable {
    enum ImageSource: Equatable, Sendable {
        /// An http(s) link with an image extension, or under an image-like key (`avatar`, `thumbnailUrl`).
        case remote
        /// A `data:image/…` URI, decoded locally.
        case inline
    }

    /// An http(s) URL.
    var link: URL?
    /// The link has query parameters, which Query opens as a JSON object.
    var linkHasQuery = false
    var image: ImageSource?
    /// Decodes that succeed on the string (JWT, Base64, URL, `\uXXXX`), most specific first.
    var decodes: [PasteDecodeKind] = []
    /// A Unix timestamp (10 digits as seconds, 13 as milliseconds) within 2000–2100.
    var date: Date?
    var dateHasMilliseconds = false
    var color: JSONColor?

    /// Strings longer than this (UTF-16 units) are only checked for a `data:image/` prefix.
    static let detailLimit = 16_384
    /// Shorter strings are not offered Base64: in JSON they are mostly words and identifiers.
    static let minimumBase64Length = 16
    static let decodeKinds: Set<PasteDecodeKind> = [.jwt, .base64, .url, .unicodeEscape]
    /// Same range as the paste offer: 2000-01-01 ..< 2100-01-01 UTC.
    private static let timestampRange: ClosedRange<Int64> = 946_684_800...4_102_444_799

    init(link: URL? = nil, linkHasQuery: Bool = false, image: ImageSource? = nil, decodes: [PasteDecodeKind] = [],
         date: Date? = nil, dateHasMilliseconds: Bool = false, color: JSONColor? = nil) {
        self.link = link
        self.linkHasQuery = linkHasQuery
        self.image = image
        self.decodes = decodes
        self.date = date
        self.dateHasMilliseconds = dateHasMilliseconds
        self.color = color
    }

    /// Objects and arrays have nothing; numbers can be timestamps; strings get every check.
    init(_ m: JSONMember, in u: [UInt16]) {
        self.init()
        let r = m.valueRange
        switch m.kind {
        case .object, .array:
            return
        case .scalar:
            guard r.length <= 20 else { return }
            setDate(String(decoding: u[r.location..<NSMaxRange(r)], as: UTF16.self))
        case .string:
            guard r.length <= Self.detailLimit + 2 else {
                let head = String(decoding: u[(r.location + 1)..<(r.location + 1 + 16)], as: UTF16.self)
                if Self.isDataImage(head) { image = .inline }
                return
            }
            self = JSONValueInsight(string: JSONLocator.valueText(m, in: u), key: m.key)
        }
    }

    init(string value: String, key: String?) {
        self.init()
        if Self.isDataImage(value) {
            image = .inline
            return
        }
        if let url = Self.webURL(value) {
            link = url
            linkHasQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.isEmpty == false
            if Self.looksLikeImage(url, key: key) { image = .remote }
        }
        color = Self.color(value)
        setDate(value)
        if color == nil, date == nil {
            decodes = (PasteDecodeDetector.candidates(in: value) ?? []).map(\.kind).filter {
                Self.decodeKinds.contains($0) && ($0 != .base64 || value.utf16.count >= Self.minimumBase64Length)
            }
        }
    }

    /// What `image` would be for this string, without the other checks.
    static func imageSource(string value: String, key: String?) -> ImageSource? {
        if isDataImage(value) { return .inline }
        guard let url = webURL(value), looksLikeImage(url, key: key) else { return nil }
        return .remote
    }

    private mutating func setDate(_ text: String) {
        guard text.count == 10 || text.count == 13, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let n = Int64(text) else { return }
        let ms = text.count == 13
        guard Self.timestampRange.contains(ms ? n / 1000 : n) else { return }
        date = Date(timeIntervalSince1970: ms ? Double(n) / 1000 : Double(n))
        dateHasMilliseconds = ms
    }

    // MARK: Dates

    /// `2023-11-14 22:13:20` (with `.123` for milliseconds) in the given zone.
    static func dateText(_ date: Date, milliseconds: Bool, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        var text = String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                          c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        if milliseconds {
            text += String(format: ".%03d", min(999, Int((Double(c.nanosecond ?? 0) / 1_000_000).rounded())))
        }
        return text
    }

    /// `UTC+8`, `UTC−3:30`, `UTC` for the zone's offset at `date`.
    static func offsetText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        guard seconds != 0 else { return "UTC" }
        let sign = seconds > 0 ? "+" : "−"
        let h = abs(seconds) / 3600, m = abs(seconds) % 3600 / 60
        return m == 0 ? "UTC\(sign)\(h)" : String(format: "UTC%@%d:%02d", sign, h, m)
    }

    // MARK: Links

    /// An http(s) URL with a host and no blanks.
    static func webURL(_ text: String) -> URL? {
        let lower = text.prefix(8).lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://"), text.utf16.count <= 8_192,
              !text.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control }),
              let url = URL(string: text), let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff",
                                                       "heic", "heif", "avif", "ico"]
    private static let imageWords: Set<String> = ["image", "img", "avatar", "icon", "logo", "photo", "picture", "pic",
                                                  "thumbnail", "thumb", "cover", "banner", "poster", "favicon", "screenshot"]

    static func looksLikeImage(_ url: URL, key: String?) -> Bool {
        if imageExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let key else { return false }
        return words(of: key).contains { imageWords.contains($0) || ($0.hasSuffix("s") && imageWords.contains(String($0.dropLast()))) }
    }

    /// `profile_imageURL` → `profile`, `image`, `url`.
    static func words(of key: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for ch in key {
            if !(ch.isLetter || ch.isNumber) {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                if ch.isUppercase, let p = previous, p.isLowercase || p.isNumber, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(ch)
            }
            previous = ch
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }

    /// The link's query as a JSON object, in the order the names first appear. A repeated name gives an
    /// array; a name with no `=` gives null. Values are percent-decoded; `+` is left as it is.
    static func queryJSON(_ url: URL) -> String? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, !items.isEmpty else {
            return nil
        }
        var names: [String] = []
        var values: [String: [String?]] = [:]
        for item in items {
            if values[item.name] == nil { names.append(item.name) }
            values[item.name, default: []].append(item.value)
        }
        func literal(_ v: String?) -> String { v.map(quoted) ?? "null" }
        let members = names.map { name -> String in
            let list = values[name] ?? []
            let value = list.count == 1 ? literal(list[0]) : "[" + list.map(literal).joined(separator: ",") + "]"
            return quoted(name) + ":" + value
        }
        let compact = "{" + members.joined(separator: ",") + "}"
        if case .formatted(let pretty, _) = JSONFormatter.format(text: compact, selection: nil) { return pretty }
        return compact
    }

    static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    // MARK: Data URIs

    static func isDataImage(_ text: String) -> Bool {
        text.prefix(11).lowercased() == "data:image/"
    }

    // MARK: Colors

    /// `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`, `rgb()` / `rgba()` (numbers or percentages, commas or
    /// spaces, `/ alpha`) and `hsl()` / `hsla()`.
    static func color(_ text: String) -> JSONColor? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard s.utf16.count <= 64 else { return nil }
        if s.hasPrefix("#") { return hexColor(s.dropFirst()) }
        for name in ["rgba", "rgb", "hsla", "hsl"] where s.hasPrefix(name + "(") && s.hasSuffix(")") {
            let inner = s.dropFirst(name.count + 1).dropLast()
            let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
            guard parts.count == 3 || parts.count == 4 else { return nil }
            let alpha = parts.count == 4 ? fraction(parts[3]) : 1
            guard let alpha else { return nil }
            if name.hasPrefix("rgb") {
                let channels = parts.prefix(3).map(channel)
                guard let r = channels[0], let g = channels[1], let b = channels[2] else { return nil }
                return JSONColor(red: r, green: g, blue: b, alpha: alpha)
            }
            guard let h = Double(parts[0].replacingOccurrences(of: "deg", with: "")),
                  parts[1].hasSuffix("%"), parts[2].hasSuffix("%"),
                  let sat = fraction(parts[1]), let light = fraction(parts[2]) else { return nil }
            let (r, g, b) = hslToRGB(h, sat, light)
            return JSONColor(red: r, green: g, blue: b, alpha: alpha)
        }
        return nil
    }

    private static func hexColor(_ hex: Substring) -> JSONColor? {
        guard [3, 4, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
        let digits = hex.count <= 4 ? hex.flatMap { [$0, $0] } : Array(hex)
        var v: [Double] = []
        for i in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(digits[i...i + 1]), radix: 16) else { return nil }
            v.append(Double(byte) / 255)
        }
        return JSONColor(red: v[0], green: v[1], blue: v[2], alpha: v.count == 4 ? v[3] : 1)
    }

    /// `0`–`255` or a percentage.
    private static func channel(_ s: String) -> Double? {
        if s.hasSuffix("%") { return fraction(s) }
        guard let n = Double(s), (0...255).contains(n) else { return nil }
        return n / 255
    }

    /// `0`–`1` or a percentage.
    private static func fraction(_ s: String) -> Double? {
        if s.hasSuffix("%") {
            guard let n = Double(s.dropLast()), (0...100).contains(n) else { return nil }
            return n / 100
        }
        guard let n = Double(s), (0...1).contains(n) else { return nil }
        return n
    }

    private static func hslToRGB(_ hue: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func component(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (component(h + 1.0 / 3), component(h), component(h - 1.0 / 3))
    }
}

/// A `data:` URI's media type and bytes. Base64 payloads may be unpadded or wrapped; others are percent-decoded.
struct DataURI: Equatable, Sendable {
    var mimeType: String
    var data: Data

    static func parse(_ text: String) -> DataURI? {
        guard text.prefix(5).lowercased() == "data:", let comma = text.firstIndex(of: ",") else { return nil }
        let meta = text[text.index(text.startIndex, offsetBy: 5)..<comma].split(separator: ";")
        let mime = meta.first.map { String($0).lowercased() }.flatMap { $0.contains("/") ? $0 : nil } ?? "text/plain"
        let isBase64 = meta.dropFirst().contains { $0.lowercased() == "base64" }
        let payload = text[text.index(after: comma)...]
        let data: Data?
        if isBase64 {
            var b64 = payload.filter { !$0.isWhitespace }
                .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            if b64.contains("%") { b64 = b64.removingPercentEncoding ?? b64 }
            let rem = b64.utf8.count % 4
            if rem > 0 { b64 += String(repeating: "=", count: 4 - rem) }
            data = Data(base64Encoded: b64)
        } else {
            data = String(payload).removingPercentEncoding.map { Data($0.utf8) }
        }
        guard let data, !data.isEmpty else { return nil }
        return DataURI(mimeType: mime, data: data)
    }

    /// `png` for `image/png`, `svg` for `image/svg+xml`, `jpg` for `image/jpeg`.
    var fileExtension: String { Self.fileExtension(forMIMEType: mimeType) ?? "png" }

    static func fileExtension(forMIMEType mime: String) -> String? {
        let subtype = mime.lowercased().split(separator: "/").dropFirst().first.map(String.init)
        guard var subtype, !subtype.isEmpty else { return nil }
        if let plus = subtype.firstIndex(of: "+") { subtype = String(subtype[..<plus]) }
        switch subtype {
        case "jpeg", "pjpeg": return "jpg"
        case "x-icon", "vnd.microsoft.icon": return "ico"
        default: return subtype.allSatisfy({ $0.isLetter || $0.isNumber }) ? subtype : nil
        }
    }
}
