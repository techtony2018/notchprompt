import Foundation

enum ScriptLinkLoaderError: LocalizedError {
    case invalidURL
    case emptyContent
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Please enter a valid http or https link."
        case .emptyContent:
            return "The link did not contain readable text."
        case .badStatus(let statusCode):
            return "The link returned HTTP \(statusCode)."
        }
    }
}

enum ScriptLinkLoader {
    static func loadScript(from rawLink: String) async throws -> String {
        let trimmed = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ScriptLinkLoaderError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw ScriptLinkLoaderError.badStatus(httpResponse.statusCode)
        }

        let rawText = decode(data, response: response)
        let cleaned = clean(rawText)
        guard !cleaned.isEmpty else {
            throw ScriptLinkLoaderError.emptyContent
        }
        return cleaned
    }

    static func clean(_ rawText: String) -> String {
        var text = rawText
        text = text.replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<style[^>]*>.*?</style>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</p\\s*>|</div\\s*>|</li\\s*>|</h[1-6]\\s*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = decodeHTMLEntities(text)
        text = text.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*[-*_]{3,}\s*$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*>\s?"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"`{1,3}"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[*_~]{1,3}"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*\d+\.\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)\bhttps?://\S+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        text = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n")
        text = text.replacingOccurrences(of: #"\n[ \t]*\n[ \t\n]*"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decode(_ data: Data, response: URLResponse) -> String {
        let encodings = preferredEncodings(from: data, response: response)
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func preferredEncodings(from data: Data, response: URLResponse) -> [String.Encoding] {
        var encodings: [String.Encoding] = []
        if let httpResponse = response as? HTTPURLResponse,
           let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
           let charsetEncoding = encoding(fromCharsetIn: contentType) {
            encodings.append(charsetEncoding)
        }
        if let asciiPreview = String(data: data.prefix(4096), encoding: .ascii),
           let metaEncoding = encoding(fromCharsetIn: asciiPreview) {
            encodings.append(metaEncoding)
        }
        encodings.append(contentsOf: [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1, .windowsCP1252])
        return encodings.reduce(into: []) { unique, encoding in
            if !unique.contains(encoding) {
                unique.append(encoding)
            }
        }
    }

    private static func encoding(fromCharsetIn text: String) -> String.Encoding? {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)charset\s*=\s*["']?([A-Za-z0-9._-]+)"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return encoding(forCharset: String(text[range]))
    }

    private static func encoding(forCharset charset: String) -> String.Encoding? {
        switch charset.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "utf-8", "utf8":
            return .utf8
        case "utf-16", "utf16":
            return .utf16
        case "utf-16le":
            return .utf16LittleEndian
        case "utf-16be":
            return .utf16BigEndian
        case "iso-8859-1", "latin1", "latin-1":
            return .isoLatin1
        case "windows-1252", "cp1252":
            return .windowsCP1252
        case "shift-jis", "shift_jis", "sjis":
            return .shiftJIS
        case "gb18030", "gbk", "gb2312":
            return .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "big5":
            return .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        default:
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
            return .init(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        }
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        var decoded = text
        let replacements = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&lt;": "<",
            "&gt;": ">"
        ]
        for (entity, character) in replacements {
            decoded = decoded.replacingOccurrences(of: entity, with: character)
        }
        decoded = decoded.replacingOccurrences(of: #"&#(\d+);"#, with: { match in
            guard let value = Int(match.dropFirst(2).dropLast()),
                  let scalar = UnicodeScalar(value) else { return String(match) }
            return String(Character(scalar))
        }, options: .regularExpression)
        return decoded
    }
}

private extension String {
    func replacingOccurrences(
        of pattern: String,
        with replacement: (Substring) -> String,
        options: String.CompareOptions
    ) -> String {
        guard options.contains(.regularExpression),
              let regex = try? NSRegularExpression(pattern: pattern) else {
            return self
        }
        let source = self as NSString
        let result = NSMutableString(string: self)
        let nsRange = NSRange(location: 0, length: source.length)
        for match in regex.matches(in: self, range: nsRange).reversed() {
            let matchedText = source.substring(with: match.range)
            result.replaceCharacters(in: match.range, with: replacement(Substring(matchedText)))
        }
        return result as String
    }
}
