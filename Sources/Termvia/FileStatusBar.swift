import AppKit
import SwiftUI
import TermviaCore

struct FileStatusBar: NSViewRepresentable {
    let count: Int
    let selectedCount: Int
    let role: String
    let actions: () -> AnyView
    @Environment(\.locale) private var locale
    func makeNSView(context: Context) -> StatusView { StatusView() }
    func updateNSView(_ view: StatusView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier("Termvia.FileStatus." + role)
        view.count.stringValue = T("%d 项", count)
        view.selection.stringValue = selectedCount > 0 ? T("已选 %d 项", selectedCount) : ""
        view.makeMenu = { NSHostingMenu(rootView: actions().environment(\.locale, locale)) }
    }
    final class StatusView: NSView {
        let count = NSTextField(labelWithString: "")
        let selection = NSTextField(labelWithString: "")
        var makeMenu: (() -> NSMenu)?
        override init(frame: NSRect) {
            super.init(frame: frame)
            for label in [count, selection] {
                label.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
                label.textColor = .tertiaryLabelColor; label.lineBreakMode = .byTruncatingTail
                label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label)
            }
            NSLayoutConstraint.activate([
                count.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), count.centerYAnchor.constraint(equalTo: centerYAnchor),
                selection.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), selection.centerYAnchor.constraint(equalTo: count.centerYAnchor),
                selection.leadingAnchor.constraint(greaterThanOrEqualTo: count.trailingAnchor, constant: 8)
            ])
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(convert(point, from: superview)) ? self : nil
        }
        override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }
}
