import AppKit
import SwiftUI
import TermviaCore

/// A system text field reserves a trailing slot for refresh, including during
/// editing, so long paths never run underneath the button.
struct NativePathField: NSViewRepresentable {
    @Binding var text: String
    let busy: Bool
    let submit: () -> Void
    let refresh: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> Container {
        let view = Container()
        view.field.delegate = context.coordinator
        view.field.target = context.coordinator; view.field.action = #selector(Coordinator.commit)
        view.button.target = context.coordinator; view.button.action = #selector(Coordinator.reload)
        return view
    }
    func updateNSView(_ view: Container, context: Context) {
        context.coordinator.parent = self
        if view.field.stringValue != text { view.field.stringValue = text }
        view.field.placeholderString = T("路径"); view.field.setAccessibilityLabel(T("路径"))
        view.button.setAccessibilityLabel(T("刷新目录")); view.button.toolTip = T("刷新目录")
        view.field.isEnabled = context.environment.isEnabled; view.button.isEnabled = context.environment.isEnabled && !busy
        view.button.image = busy ? nil : NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        view.spinner.isHidden = !busy
        if busy { view.spinner.startAnimation(nil) } else { view.spinner.stopAnimation(nil) }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativePathField
        init(parent: NativePathField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) { if let field = notification.object as? NSTextField { parent.text = field.stringValue } }
        @objc func commit() { parent.submit() }
        @objc func reload() { parent.refresh() }
    }
    final class PathCell: NSTextFieldCell {
        override func drawingRect(forBounds rect: NSRect) -> NSRect {
            var rect = super.drawingRect(forBounds: rect); rect.size.width = max(0, rect.width - 24); return rect
        }
    }
    final class RefreshButton: NSButton {
        private var cursorTracking: NSTrackingArea?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let cursorTracking { removeTrackingArea(cursorTracking) }
            let area = NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area); cursorTracking = area
        }
        override func resetCursorRects() {
            super.resetCursorRects(); addCursorRect(bounds, cursor: .arrow)
        }
        override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    }
    final class Container: NSView {
        let field = NSTextField()
        let button = RefreshButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)!, target: nil, action: nil)
        let spinner = NSProgressIndicator()
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            // The field editor may overlap the trailing accessory. Resolve the
            // accessory first so refresh never becomes an editing target.
            if button.frame.contains(local) { return button }
            return super.hitTest(point)
        }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 24) }
        override init(frame: NSRect) {
            super.init(frame: frame)
            field.cell = PathCell(textCell: "")
            field.isEditable = true; field.isSelectable = true; field.isBezeled = true; field.bezelStyle = .roundedBezel
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize); field.controlSize = .small
            field.focusRingType = .default
            button.isBordered = false; button.controlSize = .small
            spinner.style = .spinning; spinner.controlSize = .mini; spinner.isDisplayedWhenStopped = false
            for child in [field, button, spinner] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: leadingAnchor), field.trailingAnchor.constraint(equalTo: trailingAnchor), field.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -4), button.centerYAnchor.constraint(equalTo: centerYAnchor), button.widthAnchor.constraint(equalToConstant: 20), button.heightAnchor.constraint(equalToConstant: 20),
                spinner.centerXAnchor.constraint(equalTo: button.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }
}
