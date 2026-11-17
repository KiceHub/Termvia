import AppKit
import TermviaCore

/// Icon-free app dialogs with system-rendered controls and content-sized panels.
@MainActor final class CompactAlert: NSObject {
    private final class Content: NSView {
        override var isFlipped: Bool { true }
    }
    private final class Glass: NSGlassEffectView {
        func alignWindowBoundary() {
            guard let frame = superview else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            frame.wantsLayer = true
            let changed = frame.layer?.cornerRadius != cornerRadius || frame.layer?.cornerCurve != .continuous || frame.layer?.masksToBounds != true
            frame.layer?.cornerRadius = cornerRadius
            frame.layer?.cornerCurve = .continuous
            frame.layer?.masksToBounds = true
            frame.layer?.removeAnimation(forKey: "cornerRadius")
            frame.layer?.removeAnimation(forKey: "cornerCurve")
            frame.layer?.removeAnimation(forKey: "masksToBounds")
            CATransaction.commit()
            if changed { window?.invalidateShadow() }
        }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); alignWindowBoundary() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); alignWindowBoundary() }
        override func layout() { super.layout(); alignWindowBoundary() }
        override func viewWillDraw() { alignWindowBoundary(); super.viewWillDraw() }
    }
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
            (contentView as? Glass)?.alignWindowBoundary()
            super.order(place, relativeTo: otherWin)
        }
        var cancel: (() -> Void)?
        override func cancelOperation(_ sender: Any?) { cancel?() }
    }
    var messageText = ""
    var informativeText = ""
    var accessoryView: NSView?
    var showsSuppressionButton = false
    let suppressionButton: NSButton? = NSButton(checkboxWithTitle: T("不再提示"), target: nil, action: nil)
    private(set) var buttons: [NSButton] = []
    let window: NSPanel
    private var finished = false
    private var runningModal = false
    private var closeObserver: NSObjectProtocol?

    override init() {
        window = Panel(contentRect: .init(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isExcludedFromWindowsMenu = true; window.tabbingMode = .disallowed
        window.isOpaque = false; window.backgroundColor = .clear
        window.hasShadow = true; window.animationBehavior = .alertPanel
        window.preventsApplicationTerminationWhenModal = false
        window.setAccessibilitySubrole(.dialog)
        (window as? Panel)?.cancel = { [weak self] in
            guard let self, let button = self.buttons.first(where: { $0.keyEquivalent == "\u{1b}" }) else { return }
            self.respond(.init(rawValue: button.tag))
        }
    }
    @discardableResult func addButton(withTitle title: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(pressed(_:)))
        button.tag = 1000 + buttons.count
        if buttons.isEmpty { button.keyEquivalent = "\r" }
        else if title == T("取消") { button.keyEquivalent = "\u{1b}" }
        else if title == T("不保存") { button.keyEquivalent = "d"; button.keyEquivalentModifierMask = [.command] }
        buttons.append(button); return button
    }
    private func label(_ text: String, title: Bool, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = title ? .boldSystemFont(ofSize: 14) : .systemFont(ofSize: 13)
        field.textColor = title ? .labelColor : .secondaryLabelColor
        field.alignment = .center; field.isSelectable = !title
        field.maximumNumberOfLines = title ? 3 : 0
        field.lineBreakMode = title ? .byTruncatingTail : .byCharWrapping
        field.preferredMaxLayoutWidth = width; field.toolTip = text
        let height = ceil(field.cell!.cellSize(forBounds: .init(x: 0, y: 0, width: width, height: 100_000)).height)
        field.frame = .init(x: 0, y: 0, width: width, height: height)
        return field
    }
    func layout() {
        if buttons.isEmpty { addButton(withTitle: T("确定")) }
        let padding: CGFloat = 20, gap: CGFloat = 12, buttonHeight: CGFloat = 32
        let font = NSFont.systemFont(ofSize: 13)
        let minimumButtonWidth = max(104, buttons.map { ceil(($0.title as NSString).size(withAttributes: [.font: font]).width) + 48 }.max() ?? 104)
        let accessorySize = accessoryView.map { $0.frame.isEmpty ? $0.fittingSize : $0.frame.size } ?? .zero
        let width = max(300, accessorySize.width + padding * 2, minimumButtonWidth + padding * 2)
        let contentWidth = width - padding * 2
        let root = Content()
        var y = padding
        func append(_ view: NSView, spacing: CGFloat) {
            y += spacing
            view.translatesAutoresizingMaskIntoConstraints = true
            view.frame.origin = .init(x: (width - view.frame.width) / 2, y: y)
            root.addSubview(view); y += view.frame.height
        }
        append(label(messageText, title: true, width: contentWidth), spacing: 0)
        if !informativeText.isEmpty {
            let detail = label(informativeText, title: false, width: contentWidth)
            let limit = min(200, (NSScreen.main?.visibleFrame.height ?? 800) * 0.3)
            if detail.frame.height > limit {
                let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: contentWidth, height: limit))
                scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
                let document = Content(frame: detail.frame)
                document.addSubview(detail); scroll.documentView = document
                append(scroll, spacing: 8)
            } else { append(detail, spacing: 8) }
        }
        if let accessoryView {
            accessoryView.setFrameSize(accessorySize)
            append(accessoryView, spacing: 16)
        }
        if showsSuppressionButton, let suppressionButton {
            suppressionButton.sizeToFit(); append(suppressionButton, spacing: 12)
        }
        let horizontal = CGFloat(buttons.count) * minimumButtonWidth + CGFloat(max(0, buttons.count - 1)) * gap <= contentWidth
        let buttonWidth = horizontal ? (contentWidth - CGFloat(buttons.count - 1) * gap) / CGFloat(buttons.count) : contentWidth
        let rowHeight = horizontal ? buttonHeight : CGFloat(buttons.count) * buttonHeight + CGFloat(buttons.count - 1) * gap
        let row = NSView(frame: .init(x: 0, y: 0, width: contentWidth, height: rowHeight))
        for (index, button) in buttons.enumerated() {
            button.font = font; button.controlSize = .large
            button.bezelStyle = .push; button.borderShape = .capsule; button.isBordered = true
            button.tintProminence = index == 0 ? .primary : .none
            button.bezelColor = index == 0 ? .systemBlue : nil
            button.translatesAutoresizingMaskIntoConstraints = true
            row.addSubview(button)
            button.frame = .init(x: horizontal ? contentWidth - CGFloat(index + 1) * buttonWidth - CGFloat(index) * gap : 0,
                                 y: horizontal ? 0 : rowHeight - CGFloat(index + 1) * buttonHeight - CGFloat(index) * gap,
                                 width: buttonWidth, height: buttonHeight)
        }
        append(row, spacing: 20)
        let contentSize = NSSize(width: width, height: ceil(y + padding))
        root.frame = .init(origin: .zero, size: contentSize)
        let glass = Glass(frame: root.frame)
        glass.style = .regular; glass.cornerRadius = 28
        glass.contentView = root
        window.contentView = glass; window.setContentSize(contentSize); window.title = messageText
        alignGlassBoundary()
        if let field = accessoryView as? NSTextField { window.initialFirstResponder = field }
    }
    private func alignGlassBoundary() {
        (window.contentView as? Glass)?.alignWindowBoundary()
    }
    func beginSheetModal(for parent: NSWindow, completionHandler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        window.styleMask.insert(.docModalWindow)
        layout(); finished = false
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.respond(.cancel) }
        }
        parent.beginSheet(window) { [self] response in
            finished = true; window.orderOut(nil)
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver); self.closeObserver = nil }
            completionHandler?(response)
        }
        // Presenting as a sheet can replace the window frame.
        alignGlassBoundary()
    }
    func runModal() -> NSApplication.ModalResponse {
        layout(); finished = false; runningModal = true; window.center()
        let response = NSApp.runModal(for: window)
        runningModal = false; finished = true; window.orderOut(nil); return response
    }
    @objc private func pressed(_ sender: NSButton) { respond(.init(rawValue: sender.tag)) }
    private func respond(_ response: NSApplication.ModalResponse) {
        guard !finished else { return }; finished = true
        window.makeFirstResponder(nil)
        if let parent = window.sheetParent { parent.endSheet(window, returnCode: response) }
        else if runningModal { NSApp.stopModal(withCode: response) }
    }
    deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }
}
