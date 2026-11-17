import Foundation

/// UTF-16 offsets match AppKit's text and selection ranges. Only the edited
/// portion is scanned; caret movement uses binary search and one line of text.
struct EditorLineIndex {
    private(set) var starts = [0]
    private(set) var length = 0
    init(_ text: NSString = "") { rebuild(text) }
    mutating func rebuild(_ text: NSString) {
        length = text.length; starts = [0]
        for index in 0..<length where text.character(at: index) == 10 { starts.append(index + 1) }
    }
    mutating func processEdit(in text: NSString, range: NSRange, delta: Int) {
        // didProcessEditing reports the affected range in the final storage.
        // Validate it so a coalesced/programmatic edit can safely fall back.
        guard range.location != NSNotFound, range.location <= text.length,
              range.length <= text.length - range.location,
              text.length == length + delta, range.length >= delta else { rebuild(text); return }
        let oldEnd = NSMaxRange(range) - delta
        guard oldEnd >= range.location, oldEnd <= length else { rebuild(text); return }
        let first = upperBound(range.location), last = upperBound(oldEnd)
        var inserted: [Int] = []
        for offset in range.location..<NSMaxRange(range) where text.character(at: offset) == 10 { inserted.append(offset + 1) }
        starts.replaceSubrange(first..<last, with: inserted)
        for index in (first + inserted.count)..<starts.count { starts[index] += delta }
        length = text.length
    }
    private func upperBound(_ offset: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return low
    }
    func line(at offset: Int) -> Int { max(1, upperBound(min(max(0, offset), length))) }
    func position(at offset: Int, in text: NSString) -> String {
        let offset = min(max(0, offset), min(length, text.length)), line = line(at: offset)
        let prefix = text.substring(with: NSRange(location: starts[line - 1], length: offset - starts[line - 1]))
        return "\(line):\(prefix.count + 1)"
    }
}
