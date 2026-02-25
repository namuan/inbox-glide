import Foundation
import SwiftSoup

enum HTMLContentCleaner {
    private static let htmlStructureSelector = "html, body, article, section, div, p, span, a, table, tr, td, ul, ol, li, img, br, blockquote, pre"
    private static let trackingQueryParameterNames = [
        "url", "u", "target", "dest", "destination", "redirect", "redir", "redirect_url",
        "redirect_uri", "to", "out", "continue", "next", "goto", "return", "returnto"
    ]

    static func sanitizeHTML(_ rawHTML: String) -> String? {
        let trimmed = rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("<"), trimmed.contains(">") else { return nil }

        do {
            let document = try SwiftSoup.parse(trimmed)
            let hasHTMLStructure = try !document.select(htmlStructureSelector).isEmpty()
            guard hasHTMLStructure else { return nil }

            guard let cleaned = try SwiftSoup.clean(trimmed, Whitelist.basicWithImages()) else {
                return nil
            }
            let cleanedLinks = try sanitizeLinks(inHTML: cleaned)
            return cleanedLinks.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    static func untrackedDestination(from url: URL) -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return url
        }

        var current = url
        var visited: Set<String> = []

        for _ in 0..<6 {
            let value = current.absoluteString
            guard visited.insert(value).inserted else { break }
            guard let next = nextTrackedDestination(from: current), next.absoluteString != current.absoluteString else {
                break
            }
            current = next
        }

        return current
    }

    static func extractDisplayText(fromHTML rawHTML: String) -> String {
        do {
            let html = sanitizeHTML(rawHTML) ?? rawHTML
            let text = try SwiftSoup.parse(html).text()
            return cleanText(text)
        } catch {
            return cleanText(rawHTML)
        }
    }

    static func cleanText(_ rawText: String) -> String {
        let unescaped: String
        do {
            unescaped = try Entities.unescape(rawText)
        } catch {
            unescaped = rawText
        }

        return unescaped
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "[\\u00A0\\u2007]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizeLinks(inHTML html: String) throws -> String {
        let document = try SwiftSoup.parseBodyFragment(html)
        let links = try document.select("a[href]")

        for link in links.array() {
            let href = try link.attr("href").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = parseCandidateURL(from: href) else { continue }

            let destination = untrackedDestination(from: parsed).absoluteString
            try link.attr("href", destination)
            try link.attr("title", destination)
        }

        return try document.body()?.html() ?? html
    }

    private static func nextTrackedDestination(from url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let host = components.host?.lowercased() ?? ""

        if host.contains("urldefense.proofpoint.com"),
           let value = queryValue(in: components, forAnyOf: ["u"]),
           let decoded = decodeProofpoint(value),
           let parsed = parseCandidateURL(from: decoded) {
            return parsed
        }

        if host.hasSuffix("google.com"), components.path == "/url",
           let value = queryValue(in: components, forAnyOf: ["url", "q"]),
           let parsed = parseCandidateURL(from: value) {
            return parsed
        }

        if let value = queryValue(in: components, forAnyOf: trackingQueryParameterNames),
           let parsed = parseCandidateURL(from: value) {
            return parsed
        }

        if let fragment = components.fragment,
           let parsed = parseURLFromQueryLikeString(fragment) {
            return parsed
        }

        return nil
    }

    private static func parseURLFromQueryLikeString(_ value: String) -> URL? {
        guard let components = URLComponents(string: "https://localhost.invalid/?\(value)"),
              let queryValue = queryValue(in: components, forAnyOf: trackingQueryParameterNames) else {
            return nil
        }
        return parseCandidateURL(from: queryValue)
    }

    private static func queryValue(in components: URLComponents, forAnyOf names: [String]) -> String? {
        let allowed = Set(names.map { $0.lowercased() })

        for item in components.queryItems ?? [] {
            let normalizedName = item.name.lowercased().replacingOccurrences(of: "amp;", with: "")
            guard allowed.contains(normalizedName), let value = item.value, !value.isEmpty else {
                continue
            }
            return value
        }

        return nil
    }

    private static func parseCandidateURL(from rawValue: String) -> URL? {
        var normalized = normalizedCandidateValue(rawValue)
        guard !normalized.isEmpty else { return nil }

        if normalized.hasPrefix("//") {
            normalized = "https:\(normalized)"
        } else if normalized.lowercased().hasPrefix("www.") {
            normalized = "https://\(normalized)"
        }

        guard let parsed = URL(string: normalized),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        return parsed
    }

    private static func normalizedCandidateValue(_ rawValue: String) -> String {
        var normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        if normalized.isEmpty {
            return normalized
        }

        do {
            normalized = try Entities.unescape(normalized)
        } catch {
        }

        for _ in 0..<3 {
            guard let decoded = normalized.removingPercentEncoding, decoded != normalized else {
                break
            }
            normalized = decoded
        }

        return normalized
    }

    private static func decodeProofpoint(_ rawValue: String) -> String? {
        let normalized = normalizedCandidateValue(rawValue)
        guard !normalized.isEmpty else { return nil }

        let replaced = normalized
            .replacingOccurrences(of: "-", with: "%")
            .replacingOccurrences(of: "_", with: "/")

        let decoded = replaced.removingPercentEncoding ?? replaced
        return decoded.isEmpty ? nil : decoded
    }
}
