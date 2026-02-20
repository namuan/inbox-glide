import Foundation
import SwiftSoup

enum HTMLContentCleaner {
    private static let htmlStructureSelector = "html, body, article, section, div, p, span, a, table, tr, td, ul, ol, li, img, br, blockquote, pre"

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
            return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
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
}
