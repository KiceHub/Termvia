import Foundation

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1)
    public static let option = Self(rawValue: 2)
    public static let control = Self(rawValue: 4)
    public static let shift = Self(rawValue: 8)
}
public struct AppShortcutBinding: Codable, Equatable, Sendable {
    public var key: String
    public var modifiers: ShortcutModifiers
    public init(_ key: String, modifiers: ShortcutModifiers = .command) { self.key = key.lowercased(); self.modifiers = modifiers }
    public static let disabled = Self("", modifiers: [])
    public var isEnabled: Bool { !key.isEmpty }
    public var isValid: Bool {
        guard modifiers.rawValue & ~15 == 0 else { return false }
        if !isEnabled { return modifiers.isEmpty }
        guard key.count == 1, let scalar = key.unicodeScalars.first else { return false }
        let function = (0xF704...0xF726).contains(scalar.value)
        let supported = scalar.value >= 0x20 || [9, 13, 27].contains(scalar.value)
        return supported && (function || !modifiers.intersection([.command, .control]).isEmpty)
    }
    public func equivalent(to other: Self) -> Bool {
        func canonical(_ binding: Self) -> Self {
            let shifted = ["+": "=", "_": "-", "{": "[", "}": "]", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "|": "\\", "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0"]
            if let base = shifted[binding.key] { return Self(base, modifiers: binding.modifiers.union(.shift)) }
            return Self(binding.key, modifiers: binding.modifiers)
        }
        return canonical(self) == canonical(other)
    }
    public var display: String {
        guard isEnabled else { return T("未设置") }
        let special = [" ": T("空格"), "\r": "↩", "\t": "⇥", "\u{7f}": "⌫", "\u{1b}": "⎋", "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→"]
        var title = special[key] ?? key.uppercased()
        if let scalar = key.unicodeScalars.first, (0xF704...0xF726).contains(scalar.value) { title = "F" + String(scalar.value - 0xF704 + 1) }
        return (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "") + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "") + title
    }
}
public enum AppShortcutCommand: String, CaseIterable, Identifiable, Sendable {
    case newTab, localTerminal, showHosts, newHost, closeTab, reconnect, renameTab, previousTab, nextTab, focusTerminal, sidebar, panel, largerFont, smallerFont, defaultFont
    public var id: String { rawValue }
    public var customizable: Bool { self != .closeTab }
    public var title: String {
        switch self {
        case .newTab: return T("新建标签页")
        case .localTerminal: return T("新建本地终端")
        case .showHosts: return T("主机管理…")
        case .newHost: return T("新增主机")
        case .closeTab: return T("关闭当前会话")
        case .reconnect: return T("重新连接")
        case .renameTab: return T("重命名标签页…")
        case .previousTab: return T("上一个会话")
        case .nextTab: return T("下一个会话")
        case .focusTerminal: return T("聚焦终端")
        case .sidebar: return T("显示侧栏")
        case .panel: return T("显示底部面板")
        case .largerFont: return T("增大终端字体")
        case .smallerFont: return T("减小终端字体")
        case .defaultFont: return T("默认终端字体")
        }
    }
    public var defaultBinding: AppShortcutBinding {
        switch self {
        case .newTab: return .init("t")
        case .localTerminal: return .init("t", modifiers: [.command, .shift])
        case .showHosts: return .init("n")
        case .newHost: return .init("n", modifiers: [.command, .shift])
        case .closeTab: return .init("w")
        case .reconnect: return .init("r", modifiers: [.command, .shift])
        case .renameTab: return .disabled
        case .previousTab: return .init("[", modifiers: [.command, .shift])
        case .nextTab: return .init("]", modifiers: [.command, .shift])
        case .focusTerminal: return .init("t", modifiers: [.command, .option])
        case .sidebar: return .init("m", modifiers: [.command, .option])
        case .panel: return .init("b", modifiers: [.command, .option])
        case .largerFont: return .init("+")
        case .smallerFont: return .init("-")
        case .defaultFont: return .init("0")
        }
    }
}
public enum AppShortcutConfiguration {
    public static func binding(for command: AppShortcutCommand, overrides: [String: AppShortcutBinding]) -> AppShortcutBinding {
        command.customizable ? overrides[command.rawValue] ?? command.defaultBinding : command.defaultBinding
    }
    public static func isProtected(_ binding: AppShortcutBinding, command: AppShortcutCommand) -> Bool {
        let protected = ["q", ",", "c", "v", "x", "a", "z", "h", "m", "\t"].map { AppShortcutBinding($0) }
            + [AppShortcutBinding("z", modifiers: [.command, .shift]), AppShortcutBinding("h", modifiers: [.command, .option])]
        return protected.contains(where: { $0.equivalent(to: binding) }) || (binding.equivalent(to: AppShortcutCommand.closeTab.defaultBinding) && command != .closeTab)
    }
    public static func conflict(for command: AppShortcutCommand, binding: AppShortcutBinding, overrides: [String: AppShortcutBinding]) -> AppShortcutCommand? {
        guard binding.isEnabled else { return nil }
        return AppShortcutCommand.allCases.first { $0 != command && self.binding(for: $0, overrides: overrides).equivalent(to: binding) }
    }
    public static func validated(_ overrides: [String: AppShortcutBinding]) -> [String: AppShortcutBinding] {
        let valid = overrides.filter { key, value in
            guard let command = AppShortcutCommand(rawValue: key), command.customizable else { return false }
            return value.isValid && !isProtected(value, command: command)
        }
        var result = valid.mapValues { AppShortcutBinding($0.key, modifiers: $0.modifiers) }
        while true {
            let next = result.filter { key, value in
                guard let command = AppShortcutCommand(rawValue: key) else { return false }
                return conflict(for: command, binding: value, overrides: result) == nil
            }
            if next == result { return result }
            result = next
        }
    }
}
