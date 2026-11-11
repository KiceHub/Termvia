import Foundation
import SwiftUI

/// In-memory lifetime of a logical tab, shared by reconnect replacements.
@MainActor final class TabActivity: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var lines: [String] = []
    private var closed = false
    var isClosed: Bool { closed }
    private static let timestamp: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX")
        value.calendar = Calendar(identifier: .gregorian); value.timeZone = .autoupdatingCurrent
        value.dateFormat = "yyyy-MM-dd HH:mm:ss"; return value
    }()
    func append(_ message: String, at date: Date = Date()) {
        guard !closed else { return }
        // Bound each line as well as the count; remote errors can be large.
        let bounded = String(decoding: message.utf8.prefix(4096), as: UTF8.self)
        let line = bounded.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " · ")
        lines.append(Self.timestamp.string(from: date) + " " + line)
        if lines.count > 2000 { lines.removeFirst(lines.count - 2000) }
    }
    func close() { closed = true; lines.removeAll() }
}

struct TabLogList: View {
    @ObservedObject var activity: TabActivity
    var body: some View {
        Group {
            if activity.lines.isEmpty { EmptyPane(symbol: "text.alignleft", title: "无日志", detail: "") }
            else {
                ScrollView { LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(activity.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 2)
                    }
                } }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(AppTheme.surface)
    }
}
