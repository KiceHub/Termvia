import Foundation
import TermviaCore

struct EditorReplacementFormat: Equatable, Sendable {
    var encoding: EditorEncoding = .utf8
    var lineEnding: EditorLineEnding = .lf
}

enum EditorReplacementFailure: LocalizedError {
    case exceedsLimit, cannotEncode

    var errorDescription: String? {
        switch self {
        case .exceedsLimit: return T("仅支持 16 MB 以内的文件")
        case .cannotEncode: return T("当前编码无法无损保存此文本")
        }
    }
}

private struct EditorReplacementBuffer {
    let format: EditorReplacementFormat
    let limit: Int
    var text = ""
    private var byteCount = 0
    private var afterCR = false

    init(format: EditorReplacementFormat, limit: Int) {
        self.format = format
        self.limit = limit
    }

    mutating func append(_ value: String, keeping: Bool = true) throws {
        try Task.checkCancellation()
        guard !value.isEmpty else { return }
        let unitSize: Int
        let rawBytes: Int
        switch format.encoding {
        case .utf8:
            unitSize = 1
            rawBytes = value.utf8.count
        case .utf16LE, .utf16BE:
            unitSize = 2
            rawBytes = value.utf16.count * unitSize
        default:
            unitSize = 1
            guard let encoded = format.encoding.encode(value) else { throw EditorReplacementFailure.cannotEncode }
            rawBytes = encoded.count
        }

        // Count the bytes Save will write, including CRLF pairs across chunks.
        var extraUnits = 0
        for byte in value.utf8 {
            if byte == 13 || byte == 10 {
                if byte == 10 && afterCR { extraUnits -= 1 }
                else if format.lineEnding == .crlf { extraUnits += 1 }
            }
            afterCR = byte == 13
        }
        let bytes = rawBytes + extraUnits * unitSize
        guard bytes <= limit - byteCount else { throw EditorReplacementFailure.exceedsLimit }
        byteCount += bytes
        if keeping { text += value }
    }
}

private enum EditorReplacementPart {
    case literal(String)
    case capture(Int)

    /// Mirrors Foundation's numeric capture syntax, including $0, escaped
    /// characters, and empty captures. Stream captures into the bounded buffer
    /// even when one template repeats a large capture many times.
    static func parse(_ template: String, captureCount: Int) -> [Self] {
        let maxDigits = String(captureCount).count
        let characters = template.unicodeScalars
        var parts: [Self] = []
        var literal = ""
        var index = characters.startIndex
        while index < characters.endIndex {
            let character = characters[index]
            characters.formIndex(after: &index)
            if character == "\\" {
                if index < characters.endIndex {
                    literal.unicodeScalars.append(characters[index])
                    characters.formIndex(after: &index)
                }
            } else if character == "$", index < characters.endIndex, (48...57).contains(characters[index].value) {
                if !literal.isEmpty { parts.append(.literal(literal)); literal = "" }
                var capture = 0
                for _ in 0..<maxDigits {
                    guard index < characters.endIndex, (48...57).contains(characters[index].value) else { break }
                    capture = capture * 10 + Int(characters[index].value - 48)
                    characters.formIndex(after: &index)
                }
                parts.append(.capture(capture))
            } else {
                literal.unicodeScalars.append(character)
            }
        }
        if !literal.isEmpty { parts.append(.literal(literal)) }
        return parts
    }
}

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

    func replacement(_ value: String, at index: Int?, format: EditorReplacementFormat = .init(),
                     limit: Int = Int(EditorFileInspection.editorLimit)) throws -> String {
        let source = text as NSString
        var buffer = EditorReplacementBuffer(format: format, limit: limit)
        var offset = 0
        func appendUnchanged(upTo end: Int, keeping: Bool = true) throws {
            guard end > offset else { return }
            try buffer.append(source.substring(with: NSRange(location: offset, length: end - offset)), keeping: keeping)
        }
        func appendReplacement(for range: NSRange, match: NSTextCheckingResult? = nil,
                               parts: [EditorReplacementPart]) throws {
            if range.location > offset {
                try appendUnchanged(upTo: range.location, keeping: index == nil)
            }
            for part in parts {
                switch part {
                case .literal(let text):
                    try buffer.append(text)
                case .capture(let group):
                    guard let match, group < match.numberOfRanges else { continue }
                    let capture = match.range(at: group)
                    if capture.location != NSNotFound { try buffer.append(source.substring(with: capture)) }
                }
            }
            offset = NSMaxRange(range)
        }
        if let pattern, options.regex && (value.contains("$") || value.contains("\\")) {
            // Revisit the original buffer from its start so lookarounds,
            // anchors, and captures see the same context as the search.
            let parts = EditorReplacementPart.parse(value, captureCount: pattern.numberOfCaptureGroups)
            var matchIndex = 0
            var failure: Error?
            pattern.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: source.length)) { match, _, stop in
                if Task.isCancelled { stop.pointee = true; return }
                guard let match else { return }
                if index == nil || index == matchIndex {
                    do { try appendReplacement(for: match.range, match: match, parts: parts) }
                    catch { failure = error }
                    if failure != nil || index != nil { stop.pointee = true }
                }
                matchIndex += 1
            }
            if let failure { throw failure }
        } else {
            let parts: [EditorReplacementPart] = [.literal(value)]
            if let index {
                try appendReplacement(for: ranges[index], parts: parts)
            } else {
                for range in ranges { try appendReplacement(for: range, parts: parts) }
            }
        }
        try Task.checkCancellation()
        try appendUnchanged(upTo: source.length, keeping: index == nil)
        return buffer.text
    }
}
