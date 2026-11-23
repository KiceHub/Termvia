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
            guard let window else { return }
            scheduleConfiguration()
            NotificationCenter.default.addObserver(self, selector: #selector(sheetDidEnd(_:)), name: NSWindow.didEndSheetNotification, object: window)
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
            NotificationCenter.default.removeObserver(self, name: NSWindow.didEndSheetNotification, object: nil)
            rowStyleObservation = nil
            hostTable = nil; selectedRow = nil
        }
        @objc private func sheetDidEnd(_ notification: Notification) {
            // A row may have moved or been reused while the sheet was open.
            // Reconcile its native style once the sidebar is interactive again.
            hostTable?.needsDisplay = true
            scheduleConfiguration()
        }
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
            var ancestor = superview
            while let current = ancestor, !(current is HostGroupDragContainer) { ancestor = current.superview }
            guard let table = (ancestor as? HostGroupDragContainer)?.table else { return }
            hostTable = table
            // SwiftUI owns the table's style and can reuse rows during
            // enumeration. Apply the outline styling after it returns.
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
        private func handle(_ event: NSEvent) {
            guard let window, event.window === window, window.attachedSheet == nil,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            configureSelection()
            scheduleConfiguration()
            guard let table = hostTable, let clip = table.enclosingScrollView?.contentView,
                  clip.bounds.contains(clip.convert(event.locationInWindow, from: nil)) else { return }
            if table.row(at: table.convert(event.locationInWindow, from: nil)) == -1 { clear?() }
        }
    }
}
