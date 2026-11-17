import Foundation

/// Matching has no AppKit state and runs on a utility task. Regex instances
/// are immutable and shared; each call owns its text snapshot and result.
enum EditorSyntaxHighlighter {
    enum Style: Sendable { case keyword, number, string, comment }
    struct Span: Sendable { let range: NSRange; let style: Style }
    private static let supported: Set<String> = ["swift", "c", "h", "cpp", "hpp", "m", "mm", "go", "rs", "js", "jsx", "ts", "tsx", "py", "rb", "sh", "bash", "zsh", "json", "yaml", "yml", "toml", "ini", "conf", "xml", "html", "css", "sql", "md", "dockerfile"]
    private static let rules: [(NSRegularExpression, Style)] = [
        (#"\b(?:true|false|null|nil|None|True|False|let|var|func|class|struct|enum|import|from|return|if|else|for|while|def|function|const|async|await|public|private|try|catch|throw|in|do|case|switch|break|continue|package|type|select|fn|use|SELECT|FROM|WHERE)\b"#, Style.keyword),
        (#"\b\d+(?:\.\d+)?\b"#, .number),
        (#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, .string),
        (#"(?m)(?:^\s*#|//).*?$|/\*[\s\S]*?\*/|<!--[\s\S]*?-->"#, .comment)
    ].compactMap { pattern, style in (try? NSRegularExpression(pattern: pattern)).map { ($0, style) } }
    static func matches(in text: String, language: String, pattern: String) -> [Span] {
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard range.length <= 250000, language == "custom" || supported.contains(language), !Task.isCancelled else { return [] }
        let selected: [(NSRegularExpression, Style)]
        if language == "custom" {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            selected = [(regex, .keyword)]
        } else { selected = rules }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
        var spans: [Span] = []
        for (regex, style) in selected {
            guard !Task.isCancelled, ContinuousClock.now < deadline, spans.count < 12000 else { break }
            regex.enumerateMatches(in: text, options: .reportProgress, range: range) { match, _, stop in
                guard !Task.isCancelled, ContinuousClock.now < deadline, spans.count < 12000 else { stop.pointee = true; return }
                if let match { spans.append(.init(range: match.range, style: style)) }
            }
        }
        return spans
    }
}
