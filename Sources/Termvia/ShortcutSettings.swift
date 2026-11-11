import AppKit
import SwiftUI
import TermviaCore

struct ShortcutSettings: View {
    @ObservedObject var model: AppModel
    @State private var issue: String?
    var body: some View {
        Form {
            Section {
                ForEach(AppShortcutCommand.allCases.filter(\.customizable)) { command in
                    LabeledContent(command.title) {
                        NativeShortcutRecorder(binding: AppShortcutConfiguration.binding(for: command, overrides: model.settings.shortcutOverrides), identifier: "Termvia.Shortcut." + command.rawValue) { value in
                            do { try model.setShortcut(value, for: command); issue = nil }
                            catch { issue = error.localizedDescription }
                        }.frame(width: 148)
                    }
                }
                if let issue { Text(issue).font(.caption).foregroundStyle(.red).accessibilityIdentifier("Termvia.Shortcut.Error") }
                Button(T("恢复默认快捷键")) { model.settings.shortcutOverrides = [:]; issue = nil }
            }
            Section {
                LabeledContent(T("关闭当前会话"), value: "⌘W")
                LabeledContent(T("设置…"), value: "⌘,")
                LabeledContent(T("退出 Termvia"), value: T("按住 ⌘Q 退出"))
            }
        }.formStyle(.grouped)
    }
}
struct NativeShortcutRecorder: NSViewRepresentable {
    let binding: AppShortcutBinding
    let identifier: String
    let commit: (AppShortcutBinding) -> Void
    func makeNSView(context: Context) -> Recorder { Recorder() }
    func updateNSView(_ view: Recorder, context: Context) {
        view.binding = binding; view.commit = commit; view.setAccessibilityIdentifier(identifier); view.updateTitle()
    }
    static func dismantleNSView(_ view: Recorder, coordinator: ()) { view.stop() }
    final class Recorder: NSButton {
        var binding = AppShortcutBinding.disabled
        var commit: ((AppShortcutBinding) -> Void)?
        private var monitor: Any?
        private var resign: NSObjectProtocol?
        override init(frame: NSRect) {
            super.init(frame: frame); bezelStyle = .rounded; controlSize = .small
            font = .monospacedSystemFont(ofSize: 11, weight: .regular); target = self; action = #selector(record)
            setAccessibilityLabel(T("快捷键"))
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        func updateTitle() { title = monitor == nil ? binding.display : T("按下快捷键") }
        @objc private func record() {
            if monitor != nil { stop(); return }
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .leftMouseDown {
                    if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.stop() }
                    return event
                }
                guard event.window === self.window else { self.stop(); return event }
                let modifiers = ShortcutModifiers(event.modifierFlags)
                if AppShortcutBinding("q").matches(event) || AppShortcutBinding("w").matches(event) { self.stop(); return event }
                if event.keyCode == 53 && modifiers.isEmpty { self.stop(); return nil }
                let value = [51, 117].contains(event.keyCode) && modifiers.isEmpty ? AppShortcutBinding.disabled : AppShortcutBinding(event: event)
                self.stop(); self.commit?(value); return nil
            }
            resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.stop() }
            updateTitle()
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            if let resign { NotificationCenter.default.removeObserver(resign) }; resign = nil
            updateTitle()
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { stop() } }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) }; if let resign { NotificationCenter.default.removeObserver(resign) } }
    }
}
