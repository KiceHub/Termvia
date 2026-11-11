import AppKit
import SwiftUI

/// The toolbar has a separate hosting hierarchy. Own its context menu in AppKit
/// and dispatch commands after tracking ends, before presenting workspace UI.
struct NativeSessionTab: NSViewRepresentable {
    struct Action {
        let title: String
        let enabled: Bool
        let perform: (() -> Void)?
        init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
            self.title = title; self.enabled = enabled; self.perform = action
        }
        private init() { title = ""; enabled = false; perform = nil }
        static var separator: Self { Self() }
    }
    let content: AnyView
    let actions: [Action]
    var onDoubleClick: (() -> Void)? = nil
    var identifier: String? = nil
    func makeNSView(context: Context) -> Hosting {
        let view = Hosting(rootView: content)
        view.sizingOptions = [.intrinsicContentSize]
        return view
    }
    func updateNSView(_ view: Hosting, context: Context) {
        view.rootView = content; view.actions = actions; view.onDoubleClick = onDoubleClick
        view.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Hosting, context: Context) -> CGSize? { nsView.fittingSize }

    final class Hosting: NSHostingView<AnyView> {
        var actions: [Action] = []
        var onDoubleClick: (() -> Void)?
        func handleDoubleClick(_ event: NSEvent) -> Bool {
            let point = convert(event.locationInWindow, from: nil)
            guard event.type == .leftMouseDown, event.clickCount == 2, event.modifierFlags.intersection([.control, .option, .command]).isEmpty,
                  bounds.contains(point), point.x < bounds.maxX - 30, let onDoubleClick else { return false }
            onDoubleClick(); return true
        }
        override var mouseDownCanMoveWindow: Bool { false }
        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu(); menu.autoenablesItems = false
            for action in actions {
                guard action.perform != nil else { menu.addItem(.separator()); continue }
                let item = NSMenuItem(title: action.title, action: #selector(invoke(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = action; item.isEnabled = action.enabled
                menu.addItem(item)
            }
            return menu
        }
        override func rightMouseDown(with event: NSEvent) {
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
        }
        @objc private func invoke(_ sender: NSMenuItem) {
            guard let action = (sender.representedObject as? Action)?.perform else { return }
            RunLoop.main.perform(inModes: [.default], block: action)
        }
    }
}
