import AppKit
import SwiftUI

/// Observe clicks without consuming them: row selection, group actions,
/// drag-and-drop, scrolling and native context menus keep their normal routing.
struct HostListBlankSelection: NSViewRepresentable {
    let clear: () -> Void
    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) {
        view.clear = clear
        view.scheduleConfiguration()
    }
    static func dismantleNSView(_ view: Observer, coordinator: ()) { view.uninstall() }
    final class Observer: NSView {
        var clear: (() -> Void)?
        private var monitor: Any?
        private var selectionObserver: NSObjectProtocol?
        private weak var hostTable: NSTableView?
        private weak var selectedRow: NSTableRowView?
        private var rowStyleObservation: NSKeyValueObservation?
        private var configurationPending = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            uninstall()
            guard window != nil else { return }
            scheduleConfiguration()
            selectionObserver = NotificationCenter.default.addObserver(forName: NSTableView.selectionDidChangeNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let table = note.object as? NSTableView, table === self.hostTable else { return }
                    self.scheduleConfiguration()
                }
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handle(event); return event
            }
        }
        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }; selectionObserver = nil
            rowStyleObservation = nil
            hostTable = nil; selectedRow = nil
        }
        private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func scheduleConfiguration() {
            guard !configurationPending else { return }
            configurationPending = true
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.configurationPending = false; self.configureSelection()
                }
            }
        }
        func configureSelection() {
            guard let root = window?.contentView else { return }
            for table in descendants(root).compactMap({ $0 as? NSTableView }) where !(table is SidebarInsertionFeedback) && table.tableColumns.count == 1 && table.convert(table.bounds, to: self).intersects(bounds) {
                hostTable = table
                // SwiftUI owns the table's style. Changing it can synchronously
                // publish SwiftUI's internal selection during its own update.
                // Row styles are sufficient to preserve the outline selection.
                // SwiftUI can reuse row views that still carry their previous
                // native highlight style. Clear those alongside the table.
                // Enumeration can ask SwiftUI to update/reuse a hosted row.
                // Mutate its AppKit style only after that update has returned.
                var available: [NSTableRowView] = []
                table.enumerateAvailableRowViews { row, _ in available.append(row) }
                for row in available where row.selectionHighlightStyle != .none { row.selectionHighlightStyle = .none }
                let row = table.selectedRow >= 0 ? table.rowView(atRow: table.selectedRow, makeIfNecessary: false) : nil
                if selectedRow !== row {
                    selectedRow = row
                    rowStyleObservation = row?.observe(\.selectionHighlightStyle, options: [.new]) { [weak self] row, _ in
                        MainActor.assumeIsolated { if row.selectionHighlightStyle != .none { self?.scheduleConfiguration() } }
                    }
                }
            }
        }
        private func handle(_ event: NSEvent) {
            guard let window, event.window === window, window.attachedSheet == nil,
                  bounds.contains(convert(event.locationInWindow, from: nil)), let root = window.contentView else { return }
            configureSelection()
            scheduleConfiguration()
            for table in descendants(root).compactMap({ $0 as? NSTableView }) where !(table is SidebarInsertionFeedback) {
                guard let clip = table.enclosingScrollView?.contentView,
                      clip.bounds.contains(clip.convert(event.locationInWindow, from: nil)) else { continue }
                if table.row(at: table.convert(event.locationInWindow, from: nil)) == -1 { clear?() }
                return
            }
        }
    }
}
