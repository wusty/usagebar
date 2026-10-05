import Foundation

struct UsageSection {
    var heading: String
    var dollarSpent: String?
    var dollarLimit: String?
    var percentage: Int?
    var resets: String?
    var expires: String?
}

struct UsageData {
    var plan: String?
    var sections: [UsageSection] = []
    var lastUpdated: String?

    var primaryPercentage: Int? {
        sections.compactMap(\.percentage).first
    }

    var statusBarTitle: String {
        guard let pct = sections.first?.percentage else { return "Usage" }
        return "\(pct)%"
    }
}

enum UsageParser {
    private static let dollarRegex = try! NSRegularExpression(
        pattern: #"\$([0-9,]+(?:\.\d{2})?)\s+of\s+\$([0-9,]+(?:\.\d{2})?)\s+spent"#
    )
    private static let pctRegex = try! NSRegularExpression(
        pattern: #"(\d+)%\s+used"#
    )
    private static let resetsRegex = try! NSRegularExpression(
        pattern: #"Resets\s+([A-Za-z]+\s+\d+)"#
    )
    private static let expiresRegex = try! NSRegularExpression(
        pattern: #"Expires\s+([A-Za-z]+\s+\d+)"#
    )
    private static let planRegex = try! NSRegularExpression(
        pattern: #"usage limits\s+([A-Za-z][A-Za-z0-9 ]{0,30})"#,
        options: [.caseInsensitive]
    )
    private static let updatedRegex = try! NSRegularExpression(
        pattern: #"Last updated:\s*([^\n]+)"#,
        options: [.caseInsensitive]
    )

    static func parse(_ body: String) -> UsageData {
        var data = UsageData()

        let fullRange = NSRange(body.startIndex..., in: body)

        if let m = planRegex.firstMatch(in: body, range: fullRange),
           let r = Range(m.range(at: 1), in: body) {
            data.plan = String(body[r]).trimmingCharacters(in: .whitespaces)
        }
        if let m = updatedRegex.firstMatch(in: body, range: fullRange),
           let r = Range(m.range(at: 1), in: body) {
            data.lastUpdated = String(body[r]).trimmingCharacters(in: .whitespaces)
        }

        // Subheadings we want to suppress as their own sections (they're context within a section).
        let knownSubHeadings: Set<String> = [
            "Spend limit", "Included allowance", "Your usage limits"
        ]

        var sections: [UsageSection] = []
        var current: UsageSection?

        let lines = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for rawLine in lines {
            let line = rawLine
            let lr = NSRange(line.startIndex..., in: line)

            // Open the first section once we see the "Your usage limits" header.
            if line.lowercased().hasPrefix("your usage limits") {
                if current == nil { current = UsageSection(heading: "Usage limits") }
                continue
            }
            if line.lowercased().hasPrefix("last updated") { continue }

            if let m = dollarRegex.firstMatch(in: line, range: lr) {
                if current == nil { current = UsageSection(heading: "Usage limits") }
                if let r1 = Range(m.range(at: 1), in: line) { current?.dollarSpent = "$" + line[r1] }
                if let r2 = Range(m.range(at: 2), in: line) { current?.dollarLimit = "$" + line[r2] }
                continue
            }
            if let m = pctRegex.firstMatch(in: line, range: lr),
               let r1 = Range(m.range(at: 1), in: line),
               let pct = Int(line[r1]) {
                if current == nil { current = UsageSection(heading: "Usage limits") }
                current?.percentage = pct
                continue
            }
            if let m = resetsRegex.firstMatch(in: line, range: lr),
               let r1 = Range(m.range(at: 1), in: line) {
                current?.resets = String(line[r1])
                continue
            }
            if let m = expiresRegex.firstMatch(in: line, range: lr),
               let r1 = Range(m.range(at: 1), in: line) {
                current?.expires = String(line[r1])
                continue
            }

            // Skip the "Spend limit · Resets X" combo line's leading label.
            if knownSubHeadings.contains(line) { continue }

            // Treat short, non-prose lines as new section headings.
            // Prose (descriptions) tend to be long and contain punctuation.
            let looksLikeHeading = line.count <= 40
                && !line.contains(".")
                && !line.contains(",")
                && line.first.map(\.isLetter) == true

            if looksLikeHeading {
                if let c = current { sections.append(c) }
                current = UsageSection(heading: line)
            }
            // Otherwise: descriptive prose, ignore.
        }
        if let c = current { sections.append(c) }

        // Drop sections that ended up with no extracted data — they're probably
        // misidentified prose fragments. Also drop "Claude Design" — it's a
        // separate trial allowance the user doesn't want surfaced.
        data.sections = sections.filter { s in
            let isClaudeDesign = s.heading.localizedCaseInsensitiveContains("Claude Design")
            if isClaudeDesign { return false }
            return s.dollarSpent != nil || s.percentage != nil || s.resets != nil || s.expires != nil
        }

        return data
    }
}
