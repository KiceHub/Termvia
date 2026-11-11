import AppKit
import SwiftUI
import TermviaCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        NativeSettingsTabs(selection: $model.settingsPage, pages: [
            .init(page: .general, content: AnyView(general)),
            .init(page: .terminal, content: AnyView(terminal)),
            .init(page: .connection, content: AnyView(connection)),
            .init(page: .shortcuts, content: AnyView(ShortcutSettings(model: model))),
            .init(page: .credentials, content: AnyView(LoginSettings(model: model))),
            .init(page: .about, content: AnyView(AboutSettings()))
        ]).frame(width: 640, height: 590)
            .background(SettingsWindowBridge(appearance: model.layout.appearance, title: T("Termvia 设置")).frame(width: 0, height: 0))

#if TERMVIA_DIAGNOSTICS
            .background(AppearanceCheckProbe(role: "settings"))
#endif

    }
    private var general: some View {
        Form {
            Section {
                LabeledContent(T("外观")) {
                    NativePopUpPicker(selection: $model.layout.appearance, options: ["系统", "浅色", "深色"].map { ($0, T($0)) },
                                      label: "外观", identifier: "Termvia.Appearance").frame(width: 128)
                }
                LabeledContent(T("语言")) {
                    NativePopUpPicker(selection: $model.layout.language, options: AppLanguage.allCases.map { ($0, $0.title) },
                                      label: "语言", identifier: "Termvia.Language").frame(width: 128)
                }
            }
            Section(T("工作区")) {
                Toggle(T("显示侧栏"), isOn: $model.layout.monitorVisible)
                Toggle(T("显示底部面板"), isOn: $model.layout.panelVisible)
                Toggle(T("显示隐藏文件"), isOn: $model.layout.showHiddenFiles)
                Toggle(T("双击标签页关闭"), isOn: $model.settings.doubleClickClosesTab).accessibilityIdentifier("Termvia.DoubleClickClosesTab")
                SettingsNumberRow(title: "监控刷新间隔", value: $model.settings.monitorInterval, range: 1...30, unit: T("秒"), identifier: "Termvia.Monitor.Interval")
            }
            Section {
                Toggle(T("传输前确认"), isOn: $model.settings.confirmTransfers)
                    .accessibilityIdentifier("Termvia.ConfirmTransfers")
            } header: { Text(T("文件传输")) } footer: {
                Text(T("拖拽或右键上传、下载前确认来源与目标。此设置不关闭同名文件冲突提示。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private var terminal: some View {
        Form {
            Section(T("终端显示")) {
                SettingsNumberRow(title: "字体大小", value: integer($model.layout.fontSize), range: 10...28, unit: "pt", identifier: "Termvia.FontSize")
                SettingsNumberRow(title: "回滚行数", value: $model.settings.scrollbackLines, range: 500...100000, unit: T("行"), step: 500, identifier: "Termvia.Scrollback")
                LabeledContent(T("光标样式")) {
                    CursorShapeControl(selection: $model.settings.cursorShape).frame(width: 128, height: 24)
                }
            }
            Section(T("鼠标操作")) {
                LabeledContent(T("左键")) {
                    NativePopUpPicker(selection: $model.settings.leftMouseAction,
                                      options: TerminalLeftMouseAction.allCases.map { ($0, $0.title) },
                                      label: "左键", identifier: "Termvia.LeftMouseAction").frame(width: 128)
                }
                LabeledContent(T("右键")) {
                    NativePopUpPicker(selection: $model.settings.rightMouseAction,
                                      options: TerminalRightMouseAction.allCases.map { ($0, $0.title) },
                                      label: "右键", identifier: "Termvia.RightMouseAction").frame(width: 128)
                }
            }
            Section(T("终端留白")) {
                Grid(horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow {
                        SettingsNumberRow(title: "左", value: integer($model.settings.terminalInsets.left), range: 0...48, unit: "pt", identifier: "Termvia.Insets.Left")
                        SettingsNumberRow(title: "右", value: integer($model.settings.terminalInsets.right), range: 0...48, unit: "pt", identifier: "Termvia.Insets.Right")
                    }
                    GridRow {
                        SettingsNumberRow(title: "上", value: integer($model.settings.terminalInsets.top), range: 0...48, unit: "pt", identifier: "Termvia.Insets.Top")
                        SettingsNumberRow(title: "下", value: integer($model.settings.terminalInsets.bottom), range: 0...48, unit: "pt", identifier: "Termvia.Insets.Bottom")
                    }
                }
            }
            Section {
                Toggle(T("优先采用远端配色"), isOn: $model.settings.preferRemoteColors)
                LabeledContent(T("基础配色")) {
                    NativePopUpPicker(selection: $model.settings.terminalTheme, options: TerminalTheme.allCases.map { ($0, $0.title) },
                                      label: "基础配色", identifier: "Termvia.TerminalTheme").frame(width: 128)
                }
                if model.settings.terminalTheme == .custom {
                    ColorPicker(T("文字"), selection: paletteColor(\.foreground), supportsOpacity: false)
                    ColorPicker(T("背景"), selection: paletteColor(\.background), supportsOpacity: false)
                    ColorPicker(T("光标"), selection: paletteColor(\.cursor), supportsOpacity: false)
                    DisclosureGroup(T("ANSI 调色板")) {
                        ForEach(0..<16, id: \.self) { index in
                            ColorPicker(T("ANSI 颜色 %d", index), selection: Binding(get: { color(model.settings.customPalette.ansi[index]) }, set: { model.settings.customPalette.ansi[index] = hex($0) }), supportsOpacity: false)
                        }
                    }
                    Button(T("重置自定义配色")) { model.settings.customPalette = TerminalPalette() }
                }
                TerminalColorPreview(settings: model.settings, fontSize: model.layout.fontSize)
                    .frame(height: 100).accessibilityLabel(T("终端配色预览"))
            } header: { Text(T("配色")) } footer: {
                Text(T("保留远端通过 ANSI／OSC 提供的颜色；未提供时使用基础配色。关闭后固定使用本地调色板。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private var connection: some View {
        Form {
            Section {
                Toggle(T("屏蔽 OpenSSH 警告"), isOn: $model.settings.suppressOpenSSHWarnings)
                    .accessibilityIdentifier("Termvia.SuppressOpenSSHWarnings")
            }
            Section {
                Toggle(T("SSH 保活"), isOn: $model.settings.sshKeepAlive)
                    .accessibilityIdentifier("Termvia.SSH.KeepAlive")
                SettingsNumberRow(title: "保活间隔", value: $model.settings.sshKeepAliveInterval, range: 1...300, unit: T("秒"), identifier: "Termvia.SSH.KeepAliveInterval")
                    .disabled(!model.settings.sshKeepAlive)
            } footer: {
                Text(T("应用于新建或重新建立的 SSH 连接；连续 3 次未响应则断开。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(T("自动重连"), isOn: $model.settings.autoReconnect)
                SettingsNumberRow(title: "重试次数", value: $model.settings.reconnectAttempts, range: 1...10, identifier: "Termvia.Reconnect.Attempts").disabled(!model.settings.autoReconnect)
                SettingsNumberRow(title: "首次重试间隔", value: integer($model.settings.reconnectDelay), range: 1...30, unit: T("秒"), identifier: "Termvia.Reconnect.Delay").disabled(!model.settings.autoReconnect)
            } footer: {
                Text(T("仅重连意外断开的 SSH 会话，逐次延长等待，最长 30 秒。正常退出、手动停止、认证或主机公钥错误不会自动重试。不会恢复远端命令。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private func integer(_ value: Binding<Double>) -> Binding<Int> {
        Binding(get: { Int(value.wrappedValue) }, set: { value.wrappedValue = Double($0) })
    }
    private func paletteColor(_ key: WritableKeyPath<TerminalPalette, String>) -> Binding<Color> {
        Binding(get: { color(model.settings.customPalette[keyPath: key]) }, set: { model.settings.customPalette[keyPath: key] = hex($0) })
    }
    private func color(_ value: String) -> Color {
        let rgb = UInt32(value, radix: 16) ?? 0
        return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
    }
    private func hex(_ color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "000000" }
        func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}

private struct TerminalColorPreview: NSViewRepresentable {
    let settings: AppSettings
    let fontSize: Double
    func makeNSView(context: Context) -> ThemedTerminalView {
        let view = ThemedTerminalView(frame: NSRect(x: 0, y: 0, width: 540, height: 100))
        view.feed(text: "termvia ~ % printf 'Hello'\r\n\u{1b}[31m● \u{1b}[32m● \u{1b}[33m● \u{1b}[34m● \u{1b}[35m● \u{1b}[36m●\u{1b}[0m  Hello, SSH\r\n")
        return view
    }
    func updateNSView(_ view: ThemedTerminalView, context: Context) {
        if view.font.pointSize != fontSize { view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
        view.configure(settings.validated())
    }
}

private struct SettingsWindowBridge: NSViewRepresentable {
    let appearance: String
    let title: String
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.identifier = NSUserInterfaceItemIdentifier("Termvia.Settings")
            if window.title != title { window.title = title }
            let resolved = AppAppearance.override(for: appearance)
            if window.appearance?.name != resolved?.name { window.appearance = resolved }
        }
    }
}
