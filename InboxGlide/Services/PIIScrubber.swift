import Foundation

enum PIIScrubber {
    static func scrub(_ text: String) -> String {
        var output = text
        output = replace(regex: "(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", in: output, with: "[email]")
        output = replace(regex: "\\b(\\+?\\d[\\d\\s\\-()]{7,}\\d)\\b", in: output, with: "[phone]")
        return output
    }

    private static func replace(regex pattern: String, in text: String, with replacement: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}
