import AppKit
import SwiftUI
import TermviaCore

extension ShortcutModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }; if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }; if flags.contains(.shift) { insert(.shift) }
    }
    var swiftUI: EventModifiers {
        var result: EventModifiers = []
        if contains(.command) { result.insert(.command) }; if contains(.option) { result.insert(.option) }
        if contains(.control) { result.insert(.control) }; if contains(.shift) { result.insert(.shift) }
        return result
    }
}
extension AppShortcutBinding {
    init(event: NSEvent) {
        let special: [UInt16: String] = [36: "\r", 76: "\r", 48: "\t", 51: "\u{7f}", 53: "\u{1b}"]
        self.init(special[event.keyCode] ?? event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "", modifiers: ShortcutModifiers(event.modifierFlags))
    }
    func matches(_ event: NSEvent) -> Bool {
        guard isEnabled else { return false }
        let actual = Self(event: event)
        if actual.equivalent(to: self) { return true }
        let shifted = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if shifted == key, actual.modifiers == modifiers { return true }
        return shifted == key && !key.contains(where: \.isLetter) && actual.modifiers.subtracting(.shift) == modifiers
    }
    var swiftUI: KeyboardShortcut? { key.first.map { KeyboardShortcut(KeyEquivalent($0), modifiers: modifiers.swiftUI) } }
}
extension View {
    func appShortcut(_ command: AppShortcutCommand, settings: AppSettings) -> some View {
        keyboardShortcut(AppShortcutConfiguration.binding(for: command, overrides: settings.shortcutOverrides).swiftUI)
    }
}
extension AppModel {
    func canPerformShortcut(_ command: AppShortcutCommand) -> Bool {
        switch command {
        case .closeTab, .renameTab, .focusTerminal: return active != nil
        case .reconnect: return active.map { !$0.isStartPage && !$0.restarting } ?? false
        case .previousTab, .nextTab: return sessions.count > 1
        default: return true
        }
    }
    func performShortcut(_ command: AppShortcutCommand) {
        guard canPerformShortcut(command) else { return }
        switch command {
        case .newTab: newStartPage()
        case .localTerminal: connect(nil)
        case .showHosts: showHosts()
        case .newHost: showHosts(); presentHostEditor()
        case .closeTab: if let active { close(active) }
        case .reconnect: if let active { reconnect(active) }
        case .renameTab: if let active { presentTabRename(active) }
        case .previousTab: selectNext(-1)
        case .nextTab: selectNext(1)
        case .focusTerminal: focusTerminal()
        case .sidebar: layout.monitorVisible.toggle()
        case .panel: layout.panelVisible.toggle()
        case .largerFont: changeFont(1)
        case .smallerFont: changeFont(-1)
        case .defaultFont: layout.fontSize = 13
        }
    }
    func setShortcut(_ binding: AppShortcutBinding, for command: AppShortcutCommand) throws {
        guard command.customizable, binding.isValid else { throw SSHError.invalid(T("请使用 ⌘、⌃ 组合键或功能键")) }
        guard !AppShortcutConfiguration.isProtected(binding, command: command) else { throw SSHError.invalid(T("此快捷键由系统保留")) }
        if let conflict = AppShortcutConfiguration.conflict(for: command, binding: binding, overrides: settings.shortcutOverrides) {
            throw SSHError.invalid(T("此快捷键已用于%@", conflict.title))
        }
        settings.shortcutOverrides[command.rawValue] = binding
    }
}

/// Scoped to the main workspace. Settings, alerts and text editors in other
/// windows keep their native key routing, including their own Close command.
@MainActor final class WorkspaceShortcutRouter {
    weak var model: AppModel?
    weak var window: NSWindow?
    private var monitor: Any?
    init(model: AppModel, window: NSWindow) {
        self.model = model; self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in self?.handle(event) == true ? nil : event }
    }
    func handle(_ event: NSEvent) -> Bool {
        handle(event, in: NSApp.keyWindow)
    }
    func handle(_ event: NSEvent, in keyWindow: NSWindow?) -> Bool {
        guard event.type == .keyDown, let model, let window, keyWindow === window, event.windowNumber == window.windowNumber,
              window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        let flags = event.modifierFlags.intersection([.command, .control])
        let function = event.charactersIgnoringModifiers?.unicodeScalars.first.map { (0xF704...0xF726).contains($0.value) } ?? false
        guard !flags.isEmpty || function else { return false }
        let overrides = model.settings.validated().shortcutOverrides
        guard let command = AppShortcutCommand.allCases.first(where: { AppShortcutConfiguration.binding(for: $0, overrides: overrides).matches(event) }), model.canPerformShortcut(command) else { return false }
        if !event.isARepeat { model.performShortcut(command) }
        return true
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
