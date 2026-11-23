import Foundation
import TermviaCore

struct EditorFindMatches: Sendable {
    let text: String
    let query: String
    let options: FindOptions
    let ranges: [NSRange]
    private let pattern: NSRegularExpression?

    func matches(query: String, options: FindOptions) -> Bool {
        self.options.caseSensitive == options.caseSensitive && self.options.wholeWord == options.wholeWord
            && self.options.regex == options.regex
            && (self.query as NSString).isEqual(to: query)
    }

    func isCurrent(text: String, query: String, options: FindOptions) -> Bool {
        // Match offsets address UTF-16 code units. Canonically equivalent
        // Swift strings can have different offsets.
        matches(query: query, options: options) && (self.text as NSString).isEqual(to: text)
    }

    init(text: String, query: String, options: FindOptions) {
        self.text = text
        self.query = query
        self.options = options
        let queryPattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        let word = #"[\p{L}\p{M}\p{N}_]"#
        let source = options.wholeWord ? "(?<!\(word))(?:\(queryPattern))(?!\(word))" : queryPattern
        let pattern = try? NSRegularExpression(pattern: source, options: options.caseSensitive ? [] : [.caseInsensitive])
        self.pattern = pattern
        var ranges: [NSRange] = []
        pattern?.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: text.utf16.count)) { result, _, stop in
            if Task.isCancelled { stop.pointee = true }
            else if let result { ranges.append(result.range) }
        }
        self.ranges = ranges
    }

    func firstMatch(atOrAfter location: Int) -> Int {
        var lower = ranges.startIndex
        var upper = ranges.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ranges[middle].location < location { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }

    func expandsTemplate(_ value: String) -> Bool {
        options.regex && (value.contains("$") || value.contains("\\"))
    }

    func replacement(_ value: String, at index: Int?) -> String {
        let source = text as NSString
        var output = ""
        var offset = 0
        func append(_ replacement: String, for range: NSRange) {
            if range.location > offset {
                output += source.substring(with: NSRange(location: offset, length: range.location - offset))
            }
            output += replacement
            offset = NSMaxRange(range)
        }
        if let pattern, expandsTemplate(value) {
            // Revisit the original buffer from its start so lookarounds,
            // anchors, and captures see the same context as the search.
            var matchIndex = 0
            pattern.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: source.length)) { match, _, stop in
                if Task.isCancelled { stop.pointee = true; return }
                guard let match else { return }
                if index == nil || index == matchIndex {
                    let replacement = pattern.replacementString(for: match, in: text, offset: 0, template: value)
                    if index == nil { append(replacement, for: match.range) }
                    else { output = replacement; stop.pointee = true }
                }
                matchIndex += 1
            }
            if index != nil || Task.isCancelled { return output }
        } else {
            if index != nil { return value }
            for range in ranges {
                if Task.isCancelled { return output }
                append(value, for: range)
            }
        }
        output += source.substring(from: offset)
        return output
    }
}
