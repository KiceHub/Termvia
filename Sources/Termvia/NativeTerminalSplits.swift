import AppKit
import QuartzCore
import TermviaCore

@MainActor final class NativeTerminalSplits: NSView {
    private var branches: [UUID: PaneSplit] = [:]
    private var panes: [UUID: Pane] = [:]
    private var root: NSView?
    private var previousLeaves: [UUID] = []
    override var isFlipped: Bool { true }
    func update(model: AppModel, tree: TerminalSplitTree) {
        layoutSubtreeIfNeeded()
        let animate = previousLeaves != tree.leaves && Set(previousLeaves) == Set(tree.leaves) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let oldFrames = animate ? panes.mapValues { $0.convert($0.bounds, to: self) } : [:]
        previousLeaves = tree.leaves
        var branchIDs = Set<UUID>()
        func build(_ tree: TerminalSplitTree) -> NSView {
            switch tree {
            case .leaf(let id):
                let pane = panes[id] ?? Pane(); panes[id] = pane
                if let session = model.session(id) {
                    pane.host.present(session, revision: model.focusRevision, canFocus: model.focusedTerminal?.id == id && model.focusTarget == .terminal && !model.hostManagerPresented && model.tabRenameTarget == nil, insets: model.settings.terminalInsets)
                    pane.label.text.stringValue = session.title; pane.label.sessionID = id
                    pane.label.text.textColor = model.focusedTerminal?.id == id ? .controlAccentColor : .secondaryLabelColor
                    pane.swap = { [weak model] source in model?.swapPanes(source, id) }
                    session.terminal.paneDrop = pane.swap
                    session.terminal.paneDragHover = { [weak pane] active in pane?.setDropTarget(active) }
                    session.terminal.registerForDraggedTypes([.init(FileDragPayload.type), PaneLabel.type])
                    pane.label.close = { [weak model, weak session] in if let session { model?.removePane(session) } }
                }
                return pane
            case .split(let id, let axis, let first, let second):
                branchIDs.insert(id)
                let split = branches[id] ?? PaneSplit(); branches[id] = split
                split.isVertical = axis
                split.setChildren(build(first), build(second)); return split
            }
        }
        let next = build(tree)
        if root !== next { root?.removeFromSuperview(); addSubview(next); root = next }
        for id in Array(branches.keys) where !branchIDs.contains(id) { branches[id]?.removeFromSuperview(); branches[id] = nil }
        let valid = Set(tree.leaves)
        for id in Array(panes.keys) where !valid.contains(id) { panes[id]?.removeFromSuperview(); panes[id] = nil }
        needsLayout = true; layoutSubtreeIfNeeded()
        for (id, oldFrame) in oldFrames {
            guard let pane = panes[id], let parent = pane.superview, let layer = pane.layer else { continue }
            let start = parent.convert(oldFrame, from: self), end = pane.frame
            guard start != end, end.width > 0, end.height > 0 else { continue }
            let anchor = layer.anchorPoint
            let dx = start.minX + start.width * anchor.x - end.minX - end.width * anchor.x
            let dy = start.minY + start.height * anchor.y - end.minY - end.height * anchor.y
            var transform = CATransform3DMakeTranslation(dx, dy, 0)
            transform = CATransform3DScale(transform, start.width / end.width, start.height / end.height, 1)
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: transform); animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            animation.duration = 0.24; animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: "Termvia.PaneSwap")
        }
    }
    override func layout() { super.layout(); root?.frame = bounds }
    final class PaneSplit: NSSplitView, NSSplitViewDelegate {
        private var ratio: CGFloat = 0.5
        private var applying = false
        override var isFlipped: Bool { true }
        override init(frame: NSRect) { super.init(frame: frame); dividerStyle = .thin; delegate = self; wantsLayer = true; clipsToBounds = false; layer?.masksToBounds = false }
        required init?(coder: NSCoder) { fatalError() }
        func setChildren(_ first: NSView, _ second: NSView) {
            guard arrangedSubviews.count != 2 || arrangedSubviews[0] !== first || arrangedSubviews[1] !== second else { return }
            applying = true
            for view in arrangedSubviews { view.removeFromSuperview() }
            addArrangedSubview(first); addArrangedSubview(second)
            applying = false; arrange()
        }
        private func arrange() {
            guard arrangedSubviews.count == 2 else { return }
            applying = true; defer { applying = false }
            let extent = max(0, isVertical ? bounds.width : bounds.height)
            let divider = min(dividerThickness, extent), length = extent - divider
            let first = max(0, min(length, length * ratio))
            if isVertical {
                arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: first, height: bounds.height)
                arrangedSubviews[1].frame = NSRect(x: first + divider, y: 0, width: length - first, height: bounds.height)
            } else {
                arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: bounds.width, height: first)
                arrangedSubviews[1].frame = NSRect(x: 0, y: first + divider, width: bounds.width, height: length - first)
            }
        }
        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) { arrange() }
        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard !applying, arrangedSubviews.count == 2 else { return }
            let length = (isVertical ? bounds.width : bounds.height) - dividerThickness
            if length > 0 { ratio = min(1, max(0, (isVertical ? arrangedSubviews[0].frame.width : arrangedSubviews[0].frame.height) / length)) }
        }
    }
    final class Pane: NSView {
        let host = TerminalHostView(), label = PaneLabel()
        var swap: ((UUID) -> Void)?
        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; addSubview(host); addSubview(label); registerForDraggedTypes([PaneLabel.type]) }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() { super.layout(); host.frame = bounds; let width = min(bounds.width, label.text.intrinsicContentSize.width + 16); label.frame = NSRect(x: max(0, bounds.width - width - 4), y: max(0, bounds.height - 26), width: width, height: 22) }
        func setDropTarget(_ active: Bool) {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = active ? 2 : 0
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            let valid = sender.draggingPasteboard.string(forType: PaneLabel.type).flatMap(UUID.init(uuidString:)).map { $0 != label.sessionID } ?? false
            setDropTarget(valid); return valid ? .move : []
        }
        override func draggingExited(_ sender: NSDraggingInfo?) { setDropTarget(false) }
        override func concludeDragOperation(_ sender: NSDraggingInfo?) { setDropTarget(false) }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { setDropTarget(false); guard let value = sender.draggingPasteboard.string(forType: PaneLabel.type), let id = UUID(uuidString: value) else { return false }; swap?(id); return true }
    }
}
@MainActor final class PaneLabel: NSView, NSDraggingSource {
    static let type = NSPasteboard.PasteboardType("app.termvia.terminal-pane")
    let text = NSTextField(labelWithString: "")
    private let material = NSGlassEffectView()
    private let content = NSView()
    var sessionID: UUID?
    var close: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        material.style = .regular; material.cornerRadius = 11; material.contentView = content
        addSubview(material); text.font = .systemFont(ofSize: 11); text.lineBreakMode = .byTruncatingTail; content.addSubview(text)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); material.frame = bounds; content.frame = bounds; text.frame = bounds.insetBy(dx: 6, dy: 3) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        guard let sessionID else { return }
        let board = NSPasteboardItem(); board.setString(sessionID.uuidString, forType: Self.type)
        let item = NSDraggingItem(pasteboardWriter: board)
        let image = NSImage(size: bounds.size); image.lockFocus(); text.stringValue.draw(at: NSPoint(x: 4, y: 3), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]); image.unlockFocus()
        item.setDraggingFrame(bounds, contents: image); let session = beginDraggingSession(with: [item], event: event, source: self); session.animatesToStartingPositionsOnCancelOrFail = true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    override func menu(for event: NSEvent) -> NSMenu? { SplitNativeMenu.make([.init(T("关闭当前终端")) { [weak self] in self?.close?() }]) }
}
