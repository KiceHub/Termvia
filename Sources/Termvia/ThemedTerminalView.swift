import AppKit
import SwiftTerm
import TermviaCore

extension TerminalCursorShape {
    var swiftTermStyle: CursorStyle {
        switch self { case .block: return .blinkBlock; case .bar: return .blinkBar; case .underline: return .blinkUnderline }
    }
}

/// Each terminal retains the palette sent by its own shell, including after
/// reattachment. No remote startup file is inspected or changed.
@MainActor final class ThemedTerminalView: LocalProcessTerminalView, @unchecked Sendable {
    private var preferences = AppSettings()
    private var configured = false
    private var observation: TerminalOscObservation?
    private var remoteColors: [Int: SwiftTerm.Color] = [:]
    private var remoteANSI: [Int: SwiftTerm.Color] = [:]
    private var replayedRecords: [String: Int] = [:]
    private var applying = false
    private var leftClickSelection: String?
    private var draggedSelection = false
    private var consumedRightClick = false
    private var reconnectKeyMonitor: Any?
    var reconnectOnReturn: (() -> Bool)?
    func handleDisconnectedReturn(_ event: NSEvent) -> Bool {
        if [36, 76].contains(event.keyCode), !event.isARepeat,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           reconnectOnReturn?() == true { return true }
        return false
    }
    func showDisconnectNotice(_ message: String, hint: String) {
        // Leave a fullscreen application's alternate buffer before appending
        // the notice. Reset attributes and margins without erasing history.
        if terminalContentSnapshot(region: .history(maximumScrollbackRows: 0))?.inputState.isAlternateBuffer == true {
            feed(text: "\u{1b}[?1049l\u{1b}[?1047l\u{1b}[?47l")
        }
        let screen = terminalContentSnapshot(region: .history(maximumScrollbackRows: 0))
        let lastContentRow = screen?.rows.last(where: { !$0.text.isEmpty })?.absoluteRow ?? 0
        let row = min(max(1, terminalDimensions.rows), max(1, max(screen?.cursorRow ?? 0, lastContentRow) - (screen?.liveTopRow ?? 0) + 1))
        feed(text: "\u{1b}[?6l\u{1b}[?69l\u{1b}[r\u{1b}[?25h\u{1b}[0m\u{1b}[\(row);1H\r\n" + message + "\r\n" + hint + "\r\n")
        requestRedraw()
    }
    var clipboardWriter: (String) -> Void = { text in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    var clipboardPaster: ((ThemedTerminalView) -> Void) = { $0.paste($0) }
    override func mouseDown(with event: NSEvent) {
        leftClickSelection = preferences.leftMouseAction == .copy && event.clickCount == 1 && event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty ? getSelection() : nil
        draggedSelection = false
        super.mouseDown(with: event)
    }
    override func mouseDragged(with event: NSEvent) { draggedSelection = true; super.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if !draggedSelection, let text = leftClickSelection, !text.isEmpty { copyText(text) }
        leftClickSelection = nil
    }
    override func rightMouseDown(with event: NSEvent) {
        guard preferences.rightMouseAction != .disabled, !event.modifierFlags.contains(.shift) else { consumedRightClick = false; super.rightMouseDown(with: event); return }
        consumedRightClick = true
        if let text = getSelection(), !text.isEmpty {
            copyText(text); selectNone()
            if preferences.rightMouseAction == .copyAndPaste { clipboardPaster(self) }
        } else { clipboardPaster(self) }
    }
    override func rightMouseUp(with event: NSEvent) {
        if consumedRightClick { consumedRightClick = false; return }
        super.rightMouseUp(with: event)
    }
    private func copyText(_ text: String) {
        clipboardWriter(text)
    }
    /// Shift the previous screen into scrollback without RIS/ED3, which would
    /// destroy it. Return to the normal buffer and reset per-process VT modes.
    func beginConnectionBoundary() {
        selectNone()
        let rows = max(1, terminalDimensions.rows)
        feed(text: "\u{1b}[?1049l\u{1b}[?1047l\u{1b}[?47l\u{1b}[!p\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l\u{1b}[?2004l\u{1b}[0m\u{1b}[r\u{1b}[\(rows);1H" + String(repeating: "\r\n", count: rows) + "\u{1b}[H")
        remoteColors.removeAll(); remoteANSI.removeAll(); replayedRecords.removeAll()
        refreshNativeColors(); scrollTo(row: Int.max); requestRedraw()
    }
    func configure(_ settings: AppSettings) {
        observeColorsIfNeeded()
        let changed = !configured || preferences.terminalTheme != settings.terminalTheme || preferences.preferRemoteColors != settings.preferRemoteColors || preferences.customPalette != settings.customPalette
        let scrollbackChanged = !configured || preferences.scrollbackLines != settings.scrollbackLines
        let cursorChanged = !configured || preferences.cursorShape != settings.cursorShape
        preferences = settings.validated(); configured = true
        if scrollbackChanged { changeScrollback(settings.scrollbackLines) }
        if cursorChanged { setCursorStyle(preferences.cursorShape.swiftTermStyle) }
        if changed { refreshNativeColors() }
    }
    nonisolated override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        Task { @MainActor [weak self] in self?.applyCursorShape(source: source, requested: newStyle) }
    }
    private func applyCursorShape(source: Terminal, requested: CursorStyle) {
        // Shell startup/reset and applications may emit DECSCUSR. Preserve the
        // user's chosen shape without writing escape sequences into their PTY.
        let style = preferences.cursorShape.swiftTermStyle
        if requested != style { setCursorStyle(style) }
        super.cursorStyleChanged(source: source, newStyle: style)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshNativeColors()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let reconnectKeyMonitor { NSEvent.removeMonitor(reconnectKeyMonitor) }; reconnectKeyMonitor = nil
        if window != nil {
            reconnectKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window, self.window?.firstResponder === self else { return event }
                return self.handleDisconnectedReturn(event) ? nil : event
            }
        }
        refreshNativeColors()
    }
    deinit { if let reconnectKeyMonitor { NSEvent.removeMonitor(reconnectKeyMonitor) } }
    private func observeColorsIfNeeded() {
        guard observation == nil else { return }
        observation = observeOscEvents { [weak self] event in
            guard [4, 10, 11, 12, 104, 110, 111, 112].contains(event.code) else { return }
            DispatchQueue.main.async { [weak self] in self?.receiveColors(event) }
        }
    }
    private func receiveColors(_ event: TerminalOscEvent) {
        let payload = String(decoding: event.payload, as: UTF8.self)
        if event.code == 4, let count = replayedRecords[payload], count > 0 {
            replayedRecords[payload] = count == 1 ? nil : count - 1
            return
        }
        let previousColors = remoteColors, previousANSI = remoteANSI
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var mutation = false
        switch event.code {
        case 10...12:
            for (offset, text) in parts.enumerated() where event.code + offset <= 12 {
                if let color = SwiftTerm.Color.parse(text) { remoteColors[event.code + offset] = color; mutation = true }
            }
        case 4:
            for index in stride(from: 0, to: max(0, parts.count - 1), by: 2) {
                if let slot = Int(parts[index]), (0..<256).contains(slot), let color = SwiftTerm.Color.parse(parts[index + 1]) { remoteANSI[slot] = color; mutation = true }
            }
        case 104:
            if event.payload.isEmpty { remoteANSI.removeAll(); mutation = true }
            else { for part in parts { if let slot = Int(part), (0..<256).contains(slot) { remoteANSI[slot] = nil; mutation = true } } }
        case 110...112: remoteColors[event.code - 100] = nil; mutation = true
        default: break
        }
        // Replayed extended palette records are identical and stop here.
        if mutation && (!preferences.preferRemoteColors || previousColors != remoteColors || previousANSI != remoteANSI) { refreshNativeColors() }
    }
    func refreshNativeColors() {
        guard !applying else { return }
        applying = true; defer { applying = false }
        observeColorsIfNeeded()
        let palette: TerminalPalette
        switch preferences.terminalTheme {
        case .system: palette = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? .daylight : TerminalPalette()
        case .midnight: palette = TerminalPalette()
        case .daylight: palette = .daylight
        case .custom: palette = preferences.customPalette.validated()
        }
        var foreground = native(palette.foreground), background = native(palette.background), cursor = native(palette.cursor)
        if preferences.terminalTheme == .system {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                foreground = NSColor.textColor.usingColorSpace(.sRGB) ?? foreground
                background = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? background
                cursor = foreground
            }
        }
        if preferences.preferRemoteColors {
            if let color = remoteColors[10] { foreground = native(color) }
            if let color = remoteColors[11] { background = native(color) }
            if let color = remoteColors[12] { cursor = native(color) }
        }
        nativeForegroundColor = foreground; nativeBackgroundColor = background; caretColor = cursor
        var ansi = palette.ansi.map { SwiftTerm.Color.parse("#" + $0)! }
        if preferences.preferRemoteColors { for (index, color) in remoteANSI where index < 16 { ansi[index] = color } }
        installColors(ansi)
        if preferences.preferRemoteColors {
            let extended = remoteANSI.filter { $0.key >= 16 }.sorted { $0.key < $1.key }.map { index, color in
                let record = String(format: "%d;rgb:%04x/%04x/%04x", index, color.red, color.green, color.blue)
                replayedRecords[record, default: 0] += 1
                return "\u{1b}]4;" + record + "\u{7}"
            }.joined()
            if !extended.isEmpty { feed(text: extended) }
        }
        requestRedraw(); superview?.needsDisplay = true
    }
    private func native(_ hex: String) -> NSColor { native(SwiftTerm.Color.parse("#" + hex)!) }
    private func native(_ color: SwiftTerm.Color) -> NSColor {
        NSColor(srgbRed: Double(color.red) / 65535, green: Double(color.green) / 65535, blue: Double(color.blue) / 65535, alpha: 1)
    }
}
