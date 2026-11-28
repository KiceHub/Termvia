import Foundation
import SwiftTerm
import TermviaCore

/// A cached index stores one entry per matching logical line, regardless of
/// how many matches a line contains. Coordinates use scroll-invariant rows.
struct TerminalFindMatches: Sendable {
    struct Location: Equatable, Sendable {
        let start: Position
        let end: Position
        fileprivate let startStamp: Int
        fileprivate let endStamp: Int

        func stillMatches(in terminal: ThemedTerminalView, state: State) -> Bool {
            func matches(row: Int, stamp: Int) -> Bool {
                guard let current = terminal.terminalContentSnapshot(region: .rows(row..<(row + 1))),
                      current.dimensions == state.dimensions, (current.bufferKind == .alt) == state.alternate,
                      let row = current.rows.first else { return false }
                return Self.rowStamp(row) == stamp
            }
            return matches(row: start.row, stamp: startStamp)
                && (start.row == end.row || matches(row: end.row, stamp: endStamp))
        }

        fileprivate static func rowStamp(_ row: TerminalContentRowSnapshot) -> Int {
            var hash = Hasher()
            hash.combine(row.isWrapped)
            for cell in row.cells {
                hash.combine(cell.width)
                // A repaint can use different code units for canonically
                // equivalent text. Preserve the exact cell contents here.
                hash.combine(cell.text.utf8.count)
                for byte in cell.text.utf8 { hash.combine(byte) }
            }
            return hash.finalize()
        }
    }

    struct Cursor: Sendable {
        let location: Location
        let index: Int
    }

    struct State: Equatable, Sendable {
        let retainedRows: Range<Int>
        let liveTopRow: Int
        let dimensions: TerminalDimensions
        let alternate: Bool
        let liveRows: [TerminalContentRowSnapshot]

        init?(in terminal: ThemedTerminalView) {
            guard let first = terminal.terminalContentSnapshot(region: .rows(Int.min..<Int.min)),
                  let live = terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: 0)),
                  first.dimensions == live.dimensions, first.bufferKind == live.bufferKind,
                  first.capturedRange.lowerBound <= live.liveTopRow else { return nil }
            retainedRows = first.capturedRange.lowerBound..<live.capturedRange.upperBound
            liveTopRow = live.liveTopRow
            dimensions = live.dimensions
            alternate = live.bufferKind == .alt
            liveRows = live.rows
        }
    }

    private struct IndexedLine: Sendable {
        let rows: Range<Int>
        let count: Int
        let offset: Int
        var lastIndex: Int { offset + count }
    }

    private let pattern: NSRegularExpression?
    private let lines: [IndexedLine]
    let state: State
    let total: Int

    init?(in terminal: ThemedTerminalView, state: State, query: String, options: FindOptions) {
        self.state = state
        let source = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        let word = #"[\p{L}\p{M}\p{N}_]"#
        pattern = try? NSRegularExpression(pattern: options.wholeWord ? "(?<!\(word))(?:\(source))(?!\(word))" : source,
                                           options: options.caseSensitive ? [] : [.caseInsensitive])
        guard let pattern else { lines = []; total = 0; return }
        var indexed: [IndexedLine] = []
        var count = 0
        let complete = Self.scan(in: terminal, state: state, rows: state.retainedRows) { line in
            var matches = 0
            Self.enumerate(pattern, in: line.text) { _ in matches += 1; return true }
            if matches > 0 {
                indexed.append(IndexedLine(rows: line.rows, count: matches, offset: count))
                count += matches
            }
            return !Task.isCancelled
        }
        guard complete else { return nil }
        lines = indexed
        total = count
    }

    /// Returns an adjacent result, preserving the current result at a disabled
    /// wrap boundary. A rebuilt index locates it by its absolute coordinates.
    func move(in terminal: ThemedTerminalView, from previous: Cursor?, sameIndex: Bool,
              forward: Bool, wraps: Bool) -> Cursor? {
        guard total > 0, let pattern else { return nil }
        let current: Int
        let exact: Bool
        if let previous, sameIndex {
            current = previous.index
            exact = true
        } else if let previous {
            (current, exact) = rank(in: terminal, after: previous.location.start, pattern: pattern)
        } else {
            current = forward ? 0 : total + 1
            exact = false
        }
        // For a missing cursor, rank is the insertion point. The new result
        // nearest its former position may have the same ordinal as before.
        var desired = forward ? current + (exact || previous == nil ? 1 : 0) : current - 1
        if !(1...total).contains(desired) {
            if wraps { desired = forward ? 1 : total }
            else if exact {
                if sameIndex { return previous }
                desired = current
            }
            else { return nil }
        }
        let lineIndex = firstIndex { $0.lastIndex >= desired }
        guard lines.indices.contains(lineIndex) else { return nil }
        let entry = lines[lineIndex]
        var location: Location?
        _ = Self.scan(in: terminal, state: state, rows: entry.rows, mapColumns: true) { line in
            var index = entry.offset
            Self.enumerate(pattern, in: line.text) { match in
                index += 1
                guard index == desired else { return true }
                location = line.location(for: match)
                return false
            }
            return false
        }
        return location.map { Cursor(location: $0, index: desired) }
    }

    private func rank(in terminal: ThemedTerminalView, after position: Position, pattern: NSRegularExpression) -> (Int, Bool) {
        let lineIndex = firstIndex { $0.rows.upperBound > position.row }
        guard lines.indices.contains(lineIndex) else { return (total + 1, false) }
        let entry = lines[lineIndex]
        var rank = entry.offset + 1
        var equal = false
        if entry.rows.contains(position.row) {
            _ = Self.scan(in: terminal, state: state, rows: entry.rows, mapColumns: true) { line in
                let offset = line.offset(of: position)
                Self.enumerate(pattern, in: line.text) { match in
                    if match.location >= offset {
                        equal = match.location == offset
                        return false
                    }
                    rank += 1
                    return true
                }
                return false
            }
        }
        return (rank, equal)
    }

    private func firstIndex(where predicate: (IndexedLine) -> Bool) -> Int {
        var lower = 0
        var upper = lines.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if predicate(lines[middle]) { upper = middle }
            else { lower = middle + 1 }
        }
        return lower
    }

    private static func enumerate(_ pattern: NSRegularExpression, in line: String, visit: (NSRange) -> Bool) {
        pattern.enumerateMatches(in: line, options: [.reportProgress], range: NSRange(location: 0, length: line.utf16.count)) { result, _, stop in
            if Task.isCancelled { stop.pointee = true }
            else if let result, result.range.length > 0 { stop.pointee = ObjCBool(!visit(result.range)) }
        }
    }

    /// Copy small batches under the terminal lock. Concatenation and regex
    /// matching take place between copies without holding the terminal lock.
    private static func scan(in terminal: ThemedTerminalView, state: State, rows: Range<Int>, mapColumns: Bool = false,
                             visit: (LogicalLine) -> Bool) -> Bool {
        let batchSize = max(1, min(128, 8192 / max(1, state.dimensions.cols)))
        var line = LogicalLine()
        var previous: TerminalContentRowSnapshot?
        for start in stride(from: rows.lowerBound, to: rows.upperBound, by: batchSize) {
            let batch = start..<min(start + batchSize, rows.upperBound)
            guard !Task.isCancelled, let snapshot = terminal.terminalContentSnapshot(region: .rows(batch)),
                  snapshot.capturedRange == batch, snapshot.dimensions == state.dimensions,
                  (snapshot.bufferKind == .alt) == state.alternate else { return false }
            for row in snapshot.rows {
                if let previous {
                    line.append(previous, next: row, mapColumns: mapColumns)
                    if !row.isWrapped {
                        if !visit(line) { return false }
                        line = LogicalLine()
                    }
                }
                previous = row
            }
        }
        if let previous {
            line.append(previous, next: nil, mapColumns: mapColumns)
            if !visit(line) { return false }
        }
        return !Task.isCancelled
    }

    private struct LogicalLine {
        private struct CellSpan {
            // A line may contain the entire scrollback. Keep just UTF-16
            // lengths and widths while mapping one match, without cell text
            // or attributes. A zero length represents a continuation cell.
            private let storage: UInt64
            var length: Int { Int(storage >> 2) }
            var width: Int { Int(storage & 3) }

            init(length: Int, width: Int) {
                storage = (UInt64(length) << 2) | UInt64(width)
            }
        }

        private struct PhysicalRow {
            let start: Int
            let length: Int
            let columns: [CellSpan]
            let stamp: Int
        }

        private var rowStart = 0
        private var offsets: [PhysicalRow] = []
        private var length = 0
        var text = ""
        var rows: Range<Int> { rowStart..<(rowStart + offsets.count) }

        mutating func append(_ row: TerminalContentRowSnapshot, next: TerminalContentRowSnapshot?, mapColumns: Bool) {
            if offsets.isEmpty { rowStart = row.absoluteRow }
            let cells = row.cells
            let columns: Int
            if next?.isWrapped == true {
                // A double-width character can wrap past one remaining blank
                // cell. That unused cell does not belong to the logical text.
                columns = cells.count - (cells.last?.isBlank == true && cells.last?.width == 1 && next?.cells.first?.width == 2 ? 1 : 0)
            } else if let last = cells.lastIndex(where: { !$0.isBlank }) {
                columns = min(cells.count, last + max(1, cells[last].width))
            } else {
                columns = 0
            }
            var count = 0
            var spans: [CellSpan] = []
            if mapColumns { spans.reserveCapacity(columns) }
            for column in 0..<columns {
                let piece = Self.text(at: column, in: cells) ?? ""
                let units = piece.utf16.count
                text += piece
                count += units
                if mapColumns { spans.append(CellSpan(length: units, width: max(1, min(2, cells[column].width)))) }
            }
            offsets.append(PhysicalRow(start: length, length: count, columns: spans, stamp: mapColumns ? Location.rowStamp(row) : 0))
            length += count
        }

        private static func text(at column: Int, in cells: [TerminalCellSnapshot]) -> String? {
            let cell = cells[column]
            if cell.isBlank, column > 0, cells[column - 1].width == 2 { return nil }
            return cell.isBlank ? " " : cell.text
        }

        func offset(of position: Position) -> Int {
            let row = offsets[position.row - rowStart]
            return row.columns.prefix(position.col).reduce(row.start) { $0 + $1.length }
        }

        func location(for match: NSRange) -> Location? {
            guard let start = position(for: match.location, end: false),
                  let end = position(for: NSMaxRange(match) - 1, end: true) else { return nil }
            return Location(start: start, end: end, startStamp: offsets[start.row - rowStart].stamp,
                            endStamp: offsets[end.row - rowStart].stamp)
        }

        private func position(for offset: Int, end: Bool) -> Position? {
            var lower = 0
            var upper = offsets.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                let row = offsets[middle]
                if offset >= row.start + row.length { lower = middle + 1 }
                else { upper = middle }
            }
            guard offsets.indices.contains(lower) else { return nil }
            let row = offsets[lower], absoluteRow = rowStart + lower
            var textOffset = row.start
            for (column, span) in row.columns.enumerated() {
                textOffset += span.length
                if offset < textOffset {
                    return Position(col: end ? column + span.width : column, row: absoluteRow)
                }
            }
            return nil
        }
    }
}
