import AppKit
import SwiftUI

/// Observe clicks without consuming them: row selection, group actions,
/// drag-and-drop, scrolling and native context menus keep their normal routing.
struct HostListBlankSelection: NSViewRepresentable {
    let clear: () -> Void
    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) {
        view.clear = clear
        DispatchQueue.main.async { view.configureSelection() }
    }
    static func dismantleNSView(_ view: Observer, coordinator: ()) { view.uninstall() }
    final class Observer: NSView {
        var clear: (() -> Void)?
        private var monitor: Any?
        private var selectionObserver: NSObjectProtocol?
        private weak var hostTable: NSTableView?
        private weak var selectedRow: NSTableRowView?
        private var tableStyleObservation: NSKeyValueObservation?
        private var rowStyleObservation: NSKeyValueObservation?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            uninstall()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.configureSelection() }
            selectionObserver = NotificationCenter.default.addObserver(forName: NSTableView.selectionDidChangeNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let table = note.object as? NSTableView, table === self.hostTable else { return }
                    self.configureSelection()
                }
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handle(event); return event
            }
        }
        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }; selectionObserver = nil
            tableStyleObservation = nil; rowStyleObservation = nil
            hostTable = nil; selectedRow = nil
        }
        private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func configureSelection() {
            guard let root = window?.contentView else { return }
            for table in descendants(root).compactMap({ $0 as? NSTableView }) where !(table is SidebarInsertionFeedback) && table.tableColumns.count == 1 && table.convert(table.bounds, to: self).intersects(bounds) {
                if hostTable !== table {
                    hostTable = table
                    tableStyleObservation = table.observe(\.selectionHighlightStyle, options: [.new]) { [weak self] table, _ in
                        MainActor.assumeIsolated { if table.selectionHighlightStyle != .none { self?.configureSelection() } }
                    }
                }
                table.selectionHighlightStyle = .none
                // SwiftUI can reuse row views that still carry their previous
                // native highlight style. Clear those alongside the table.
                table.enumerateAvailableRowViews { row, _ in row.selectionHighlightStyle = .none }
                let row = table.selectedRow >= 0 ? table.rowView(atRow: table.selectedRow, makeIfNecessary: false) : nil
                if selectedRow !== row {
                    selectedRow = row
                    rowStyleObservation = row?.observe(\.selectionHighlightStyle, options: [.new]) { row, _ in
                        MainActor.assumeIsolated { if row.selectionHighlightStyle != .none { row.selectionHighlightStyle = .none } }
                    }
                }
            }
        }
        private func handle(_ event: NSEvent) {
            guard let window, event.window === window, window.attachedSheet == nil,
                  bounds.contains(convert(event.locationInWindow, from: nil)), let root = window.contentView else { return }
            configureSelection()
            DispatchQueue.main.async { [weak self] in self?.configureSelection() }
            for table in descendants(root).compactMap({ $0 as? NSTableView }) where !(table is SidebarInsertionFeedback) {
                guard let clip = table.enclosingScrollView?.contentView,
                      clip.bounds.contains(clip.convert(event.locationInWindow, from: nil)) else { continue }
                if table.row(at: table.convert(event.locationInWindow, from: nil)) == -1 { clear?() }
                return
            }
        }
    }
}
