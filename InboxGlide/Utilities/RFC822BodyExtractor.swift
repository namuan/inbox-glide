import Foundation

enum RFC822BodyExtractor {
    static func extract(headers: [String: String], body: String) -> (text: String, html: String?) {
        let normalizedBody = body.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = collectParts(headers: headers, body: normalizedBody)

        let plainText = parts.plain
            .map { HTMLContentCleaner.cleanText($0) }
            .filter { !$0.isEmpty }
        let htmlText = parts.html
            .compactMap { HTMLContentCleaner.sanitizeHTML($0) }
            .filter { !$0.isEmpty }

        if !plainText.isEmpty {
            return (plainText.joined(separator: "\n\n"), htmlText.joined(separator: "\n\n").nilIfEmpty)
        }
        if !htmlText.isEmpty {
            let html = htmlText.joined(separator: "\n\n")
            return (HTMLContentCleaner.extractDisplayText(fromHTML: html), html)
        }

        return (HTMLContentCleaner.cleanText(normalizedBody), nil)
    }

    private static func collectParts(headers: [String: String], body: String) -> (plain: [String], html: [String]) {
        let rawContentType = headers["content-type"] ?? "text/plain"
        let contentType = rawContentType.lowercased()
        let multipartBoundary = boundaryValue(from: rawContentType) ?? implicitBoundaryValue(from: body)
        if contentType.hasPrefix("multipart/"), let boundary = multipartBoundary {
            var plain: [String] = []
            var html: [String] = []

            for rawPart in splitMultipartBody(body, boundary: boundary) {
                let (partHeaders, partBody) = splitHeadersAndBody(rawPart)
                let nested = collectParts(headers: partHeaders, body: partBody)
                plain.append(contentsOf: nested.plain)
                html.append(contentsOf: nested.html)
            }
            return (plain, html)
        }

        let transferEncoding = headers["content-transfer-encoding"]?.lowercased() ?? ""
        let decoded = decodeBody(body, transferEncoding: transferEncoding, contentType: rawContentType)

        if contentType.contains("text/html") {
            return ([], [decoded])
        }
        if contentType.contains("text/plain") || contentType.hasPrefix("text/") || contentType.isEmpty {
            return ([decoded], [])
        }

        return ([], [])
    }

    private static func splitHeadersAndBody(_ rawPart: String) -> (headers: [String: String], body: String) {
        let separator = rawPart.range(of: "\n\n")
        let headerPart = separator.map { String(rawPart[..<$0.lowerBound]) } ?? ""
        let bodyPart = separator.map { String(rawPart[$0.upperBound...]) } ?? rawPart
        return (parseHeaders(from: headerPart), bodyPart)
    }

    private static func splitMultipartBody(_ body: String, boundary: String) -> [String] {
        let delimiter = "--\(boundary)"
        let endDelimiter = "--\(boundary)--"
        let lines = body.components(separatedBy: "\n")

        var parts: [String] = []
        var current: [String] = []
        var insidePart = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == delimiter || trimmed == endDelimiter {
                if insidePart, !current.isEmpty {
                    parts.append(current.joined(separator: "\n"))
                    current.removeAll(keepingCapacity: true)
                }
                insidePart = trimmed != endDelimiter
                continue
            }
            if insidePart {
                current.append(line)
            }
        }

        if insidePart, !current.isEmpty {
            parts.append(current.joined(separator: "\n"))
        }

        return parts
    }

    private static func parseHeaders(from headerBlock: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentKey: String?

        for line in headerBlock.components(separatedBy: .newlines) {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), let currentKey {
                result[currentKey, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            result[key] = value
            currentKey = key
        }

        return result
    }

    private static func implicitBoundaryValue(from body: String) -> String? {
        let firstLine = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })

        guard let firstLine, firstLine.hasPrefix("--") else { return nil }
        let withoutPrefix = String(firstLine.dropFirst(2))
        let token = withoutPrefix
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first
            .map(String.init)?
            .replacingOccurrences(of: "--", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let token, token.count >= 6 else { return nil }
        return token
    }

    private static func boundaryValue(from contentType: String) -> String? {
        guard let match = contentType.range(of: "boundary\\s*=\\s*(\"[^\"]+\"|[^;\\s]+)", options: .regularExpression) else {
            return nil
        }
        let raw = String(contentType[match]).components(separatedBy: "=").dropFirst().joined(separator: "=")
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
    }

    private static func decodeBody(_ body: String, transferEncoding: String, contentType: String) -> String {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")

        let decodedData: Data?
        switch transferEncoding {
        case "base64":
            let compact = normalized.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            decodedData = Data(base64Encoded: compact)
        case "quoted-printable":
            decodedData = decodeQuotedPrintableToData(normalized)
        default:
            decodedData = normalized.data(using: .utf8) ?? normalized.data(using: .isoLatin1)
        }

        guard let data = decodedData else {
            return normalized
        }

        if let charset = charsetValue(from: contentType), let encoding = stringEncoding(forIANA: charset),
           let text = String(data: data, encoding: encoding) {
            return text
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func charsetValue(from contentType: String) -> String? {
        guard let match = contentType.range(of: "charset\\s*=\\s*(\"[^\"]+\"|[^;\\s]+)", options: .regularExpression) else {
            return nil
        }
        let raw = String(contentType[match]).components(separatedBy: "=").dropFirst().joined(separator: "=")
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
    }

    private static func stringEncoding(forIANA name: String) -> String.Encoding? {
        let cfName = name as CFString
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(cfName)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        return String.Encoding(rawValue: nsEncoding)
    }

    private static func decodeQuotedPrintableToData(_ text: String) -> Data {
        let normalized = text
            .replacingOccurrences(of: "=\r\n", with: "")
            .replacingOccurrences(of: "=\n", with: "")
        let scalars = Array(normalized.unicodeScalars)

        var bytes: [UInt8] = []
        bytes.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "=", index + 2 < scalars.count,
               let hi = hexValue(of: scalars[index + 1]),
               let lo = hexValue(of: scalars[index + 2]) {
                bytes.append((hi << 4) | lo)
                index += 3
                continue
            }
            bytes.append(contentsOf: String(scalar).utf8)
            index += 1
        }
        return Data(bytes)
    }

    private static func hexValue(of scalar: UnicodeScalar) -> UInt8? {
        switch scalar.value {
        case 48...57: return UInt8(scalar.value - 48)
        case 65...70: return UInt8(scalar.value - 55)
        case 97...102: return UInt8(scalar.value - 87)
        default: return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
