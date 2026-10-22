import Foundation

struct MarkdownImageDimensions: Sendable, Hashable {
    var width: Int?
    var height: Int?
}

enum MarkdownImageDimensionsAttribute: AttributedStringKey {
    typealias Value = MarkdownImageDimensions
    static let name = "TinyEdit.MarkdownImageDimensions"
}

struct MarkdownImageReference: Sendable, Equatable {
    var source: URL
    var alt: String
    var link: URL? = nil
    var dimensions: MarkdownImageDimensions = .init()
}

enum MarkdownInlinePart: Equatable {
    case text(AttributedString)
    case image(MarkdownImageReference)
}

/// Foundation still owns Markdown parsing. Only HTML runs are considered here, so fenced code,
/// inline code and escaped tags remain literal. No HTML engine or script execution is involved.
enum MarkdownInline {
    static func parts(_ text: AttributedString) -> [MarkdownInlinePart] {
        var result: [MarkdownInlinePart] = []
        for run in text.runs {
            let slice = AttributedString(text[run.range])
            if let url = run.imageURL {
                let image = MarkdownImageReference(source: url, alt: String(slice.characters), link: run.link,
                    dimensions: slice[MarkdownImageDimensionsAttribute.self] ?? .init())
                result.append(.image(image))
            } else if case .text(let previous) = result.last {
                result[result.count - 1] = .text(previous + slice)
            } else {
                result.append(.text(slice))
            }
        }
        return result
    }

    /// Foundation drops imageURL when an image is wrapped in a link. Its source position still
    /// identifies the inner image exactly, so let Foundation parse that fragment without the link.
    /// Code and escaped syntax never enter this path; no Markdown grammar is duplicated here.
    static func linkedImage(_ text: AttributedString, source: String) -> AttributedString? {
        guard let run = text.runs.first, run.imageURL == nil, let link = run.link,
              run.inlinePresentationIntent?.contains(.code) != true,
              let position = run.markdownSourcePosition, let range = Range(position, in: source) else { return nil }
        let fragment = String(source[range])
        guard fragment.hasPrefix("!["),
              let parsed = try? AttributedString(markdown: fragment),
              let url = parsed.runs.first?.imageURL,
              parsed.runs.allSatisfy({ $0.imageURL == url }) else { return nil }
        let alt = String(parsed.characters)
        var image = AttributedString(alt.isEmpty ? "\u{fffc}" : alt)
        image.imageURL = url
        image.link = link
        return image
    }

    static func sanitized(_ text: AttributedString) -> AttributedString {
        var result = AttributedString()
        for run in text.runs {
            let original = AttributedString(text[run.range])
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.inlineHTML) || intent.contains(.blockHTML),
               var converted = html(String(original.characters)) {
                var surrounding = intent
                surrounding.remove(.inlineHTML)
                surrounding.remove(.blockHTML)
                if !surrounding.isEmpty { converted.inlinePresentationIntent = surrounding }
                converted.link = run.link
                result += converted
            } else {
                var slice = AttributedString(String(original.characters))
                slice.inlinePresentationIntent = run.inlinePresentationIntent
                slice.link = run.link
                slice.imageURL = run.imageURL
                result += slice
            }
        }
        return result
    }

    /// Accept only a sequence of img/br tags and whitespace. Other HTML stays visible as source.
    private static func html(_ source: String) -> AttributedString? {
        let ns = source as NSString
        let pattern = #"<(?:\"[^\"]*\"|'[^']*'|[^'\">])*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              !source.isEmpty else { return nil }
        let tags = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
        guard !tags.isEmpty else { return nil }
        var result = AttributedString()
        var cursor = 0
        for match in tags {
            let gap = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            guard gap.allSatisfy(\.isWhitespace) else { return nil }
            result += AttributedString(gap)
            let tag = ns.substring(with: match.range)
            guard let converted = tagValue(tag) else { return nil }
            result += converted
            cursor = NSMaxRange(match.range)
        }
        let tail = ns.substring(from: cursor)
        guard tail.allSatisfy(\.isWhitespace) else { return nil }
        result += AttributedString(tail)
        return result
    }

    private static func tagValue(_ tag: String) -> AttributedString? {
        guard let head = tag.range(of: #"^<(img|br)(?=\s|/?>)"#, options: [.regularExpression, .caseInsensitive]),
              tag.hasSuffix(">") else { return nil }
        let kind = tag[head].lowercased()
        if kind == "<br" { return AttributedString("\n") }
        let body = String(tag[head.upperBound..<tag.index(before: tag.endIndex)])
        let regex = try! NSRegularExpression(pattern: #"([a-zA-Z_:][a-zA-Z0-9_:.-]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+))"#)
        let ns = body as NSString
        var attributes: [String: String] = [:]
        for match in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            let value = (2...4).first { match.range(at: $0).location != NSNotFound }!
            if attributes[key] == nil { attributes[key] = entities(ns.substring(with: match.range(at: value))) }
        }
        guard let src = attributes["src"], !src.isEmpty, let url = URL(string: src) else { return nil }
        // The object replacement character keeps images with no alt text in Foundation's run model.
        var image = AttributedString(attributes["alt"].flatMap { $0.isEmpty ? nil : $0 } ?? "\u{fffc}")
        image.imageURL = url
        func dimension(_ key: String) -> Int? {
            guard let raw = attributes[key], raw.allSatisfy(\.isNumber), let n = Int(raw), n > 0 else { return nil }
            return min(n, 4096)
        }
        image[MarkdownImageDimensionsAttribute.self] = .init(width: dimension("width"), height: dimension("height"))
        return image
    }

    private static func entities(_ text: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|amp|quot|apos|lt|gt|nbsp);"#)
        let ns = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let key = ns.substring(with: match.range(at: 1))
            let named = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": "\u{a0}"]
            let value: String?
            if key.hasPrefix("#x") { value = UInt32(key.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init).map(String.init) }
            else if key.hasPrefix("#") { value = UInt32(key.dropFirst()).flatMap(UnicodeScalar.init).map(String.init) }
            else { value = named[key] }
            if let value, let range = Range(match.range, in: result) { result.replaceSubrange(range, with: value) }
        }
        return result
    }
}
