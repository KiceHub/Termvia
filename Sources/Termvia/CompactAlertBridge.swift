import AppKit
import SwiftUI

struct CompactAlertAction {
    enum Role { case normal, cancel }
    let title: String
    let role: Role
    let action: () -> Void
    init(_ title: String, role: Role = .normal, action: @escaping () -> Void = {}) {
        self.title = title; self.role = role; self.action = action
    }
}
struct CompactAlertInput {
    let placeholder: String
    @Binding var text: String
}

extension View {
    func compactAlert(_ title: String, isPresented: Binding<Bool>, message: String = "", input: CompactAlertInput? = nil, actions: [CompactAlertAction]) -> some View {
        background(CompactAlertBridge(title: title, isPresented: isPresented, message: message, input: input, actions: actions).frame(width: 0, height: 0))
    }
}

private struct CompactAlertBridge: NSViewRepresentable {
    let title: String
    @Binding var isPresented: Bool
    let message: String
    let input: CompactAlertInput?
    let actions: [CompactAlertAction]
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> Anchor {
        let view = Anchor(); view.coordinator = context.coordinator; return view
    }
    func updateNSView(_ view: Anchor, context: Context) { context.coordinator.parent = self; context.coordinator.update() }
    static func dismantleNSView(_ view: Anchor, coordinator: Coordinator) { coordinator.dismiss() }
    final class Anchor: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); coordinator?.window = window; coordinator?.update() }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CompactAlertBridge
        weak var window: NSWindow?
        var alert: CompactAlert?
        private var field: NSTextField?
        private var observer: NSObjectProtocol?
        init(parent: CompactAlertBridge) { self.parent = parent }
        func update() {
            guard parent.isPresented else { dismiss(); return }
            guard alert == nil, let window else { return }
            if window.attachedSheet != nil {
                if observer == nil {
                    observer = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
                        DispatchQueue.main.async { self?.update() }
                    }
                }
                return
            }
            let alert = CompactAlert(); self.alert = alert
            alert.messageText = parent.title; alert.informativeText = parent.message
            if let input = parent.input {
                let field = NSTextField(string: input.text); field.placeholderString = input.placeholder
                field.frame = .init(x: 0, y: 0, width: 260, height: 24); field.delegate = self
                alert.accessoryView = field; self.field = field
            }
            let actions = parent.actions
            for action in actions {
                let button = alert.addButton(withTitle: action.title)
                if action.role == .cancel { button.keyEquivalent = "\u{1b}" }
            }
            alert.beginSheetModal(for: window) { [self] response in
                if let field, let input = parent.input { input.text = field.stringValue }
                self.alert = nil; field = nil
                let index = response.rawValue - 1000
                if actions.indices.contains(index) { actions[index].action() }
                parent.isPresented = false
            }
            if let field { alert.window.makeFirstResponder(field) }
        }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField, let input = parent.input { input.text = field.stringValue }
        }
        func dismiss() { if let alert, let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .cancel) } }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
