import AppKit
import TermviaCore

/// Confirm first, then wait for the physical Q release before terminating.
/// Keeping the app/key window alive consumes repeats instead of sending ⌘Q
/// to the next application. No nested run loop or event tap is required.
@MainActor final class HoldToQuit: ObservableObject {
    @Published private(set) var showingHint = false
    @Published private(set) var holding = false
    @Published private(set) var waitingForRelease = false
    var onQuit: (() -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    private let duration: Duration
    private let doublePressInterval: TimeInterval
    private let hintDuration: Duration
    private var monitor: Any?
    private var keyCode: UInt16?
    private var task: Task<Void, Never>?
    private var previousPress: TimeInterval?
    private var quitRequested = false
    private var feedback: QuitFeedbackController?
    var isPressed: (UInt16) -> Bool
    var isKeyDown: (UInt16) -> Bool

    init(duration: Duration = .milliseconds(600), doublePressInterval: Duration = .milliseconds(800), hintDuration: Duration = .seconds(2), isPressed: ((UInt16) -> Bool)? = nil, isKeyDown: ((UInt16) -> Bool)? = nil) {
        self.duration = max(.milliseconds(1), duration)
        self.doublePressInterval = Self.seconds(doublePressInterval)
        self.hintDuration = max(.milliseconds(1), hintDuration)
        self.isPressed = isPressed ?? { key in
            let flags = CGEventSource.flagsState(.combinedSessionState)
            return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key)) && flags.contains(.maskCommand)
                && flags.intersection([.maskShift, .maskControl, .maskAlternate]).isEmpty
        }
        self.isKeyDown = isKeyDown ?? isPressed ?? { key in CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key)) }
    }
    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    func install(onQuit: @escaping () -> Void) {
        self.onQuit = onQuit
        guard monitor == nil else { return }
        let feedback = QuitFeedbackController(shortcut: self)
        self.feedback = feedback
        onCommit = { [weak feedback] in feedback?.confirm() }
        onCancel = { [weak feedback] in feedback?.restoreWindows() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { guard let self else { return false }; return self.handle(event) == nil }
            return consumed ? nil : event
        }
    }
    func handle(_ event: NSEvent) -> NSEvent? {
        if quitRequested, event.type == .keyDown, event.keyCode == keyCode { return nil }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            if showingHint { cancel() }; return event
        }
        if event.type == .keyDown, event.keyCode == 53, showingHint { cancel(); return nil }
        if waitingForRelease {
            if event.type == .keyUp, event.keyCode == keyCode { finishQuit(before: event); return nil }
            if event.type == .keyDown, event.keyCode == keyCode { return nil }
            // Releasing Command alone is not sufficient: Q could still repeat.
            return event
        }
        if event.type == .keyDown {
            let modifiers = Self.modifiers(event)
            if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "q" {
                guard !quitRequested else { return nil }
                guard !event.isARepeat else { return nil }
                // NSEvent timestamps preserve the real press interval even if
                // delivery is delayed by a menu/layout pass on the main thread.
                let now = event.timestamp
                let doublePress = previousPress.map { now > $0 && now - $0 <= doublePressInterval } ?? false
                task?.cancel(); keyCode = event.keyCode
                if doublePress { confirmQuit(); return nil }
                previousPress = now; holding = true; showingHint = true
                beginHold(event.keyCode)
                return nil
            }
            if keyCode != nil || previousPress != nil { cancel() }
        } else if event.type == .keyUp, event.keyCode == keyCode {
            release(); return nil
        } else if event.type == .flagsChanged {
            let modifiers = Self.modifiers(event)
            if !modifiers.intersection([.shift, .control, .option]).isEmpty { previousPress = nil }
            if keyCode != nil && modifiers != .command { release() }
        }
        return event
    }
    private static func modifiers(_ event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
    }
    private func beginHold(_ key: UInt16) {
        task = Task { [weak self, duration] in
            let clock = ContinuousClock(), start = clock.now
            let deadline = start.advanced(by: duration)
            do {
                while clock.now < deadline {
                    try Task.checkCancellation()
                    guard let self, self.holding, self.keyCode == key else { return }
                    guard self.isPressed(key) else { self.release(); return }
                    try await Task.sleep(for: min(.milliseconds(20), clock.now.duration(to: deadline)))
                }
                try Task.checkCancellation()
            } catch { return }
            guard let self, self.holding, self.keyCode == key else { return }
            guard self.isPressed(key) else { self.release(); return }
            self.confirmQuit()
        }
    }
    private func confirmQuit() {
        guard !waitingForRelease, !quitRequested, let key = keyCode else { return }
        task?.cancel(); task = nil; previousPress = nil
        holding = false; waitingForRelease = true; showingHint = true
        onCommit?()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.waitingForRelease, self.keyCode == key else { return }
                if !self.isKeyDown(key) {
                    self.finishQuit()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }
    }
    private func finishQuit(before event: NSEvent? = nil) {
        guard waitingForRelease, !quitRequested, let keyCode, !isKeyDown(keyCode) else { return }
        quitRequested = true
        task?.cancel(); task = nil; previousPress = nil
        holding = false; waitingForRelease = false; showingHint = false
        // Only discard keyboard input already queued in this application after
        // confirmation, never mouse/application events or another app's queue.
        NSApp?.discardEvents(matching: .keyDown, before: event)
        onQuit?()
    }
    private func release() {
        task?.cancel(); keyCode = nil; holding = false
        task = Task { [weak self, hintDuration] in
            do { try await Task.sleep(for: hintDuration) } catch { return }
            self?.showingHint = false; self?.task = nil
        }
    }
    func cancel() {
        task?.cancel(); task = nil; keyCode = nil; previousPress = nil; quitRequested = false
        holding = false; waitingForRelease = false; showingHint = false
        onCancel?()
    }
    func uninstall() {
        cancel()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        feedback?.stop(); feedback = nil; onCommit = nil; onCancel = nil; onQuit = nil
    }
}
