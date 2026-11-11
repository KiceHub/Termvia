import AppKit
import SwiftUI
import TermviaCore

/// Group headers use their own columns, independently of indented host rows.
enum HostGroupTitleGrid {
    static let iconColumn: CGFloat = 20
    static let iconSize: CGFloat = 16
    static let spacing: CGFloat = 6
    static var textLeading: CGFloat { iconColumn + spacing }
}

/// Keep native button drawing and state, overriding only icon/text geometry.
final class HostGroupTitleCell: NSButtonCell {
    override func imageRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + (HostGroupTitleGrid.iconColumn - HostGroupTitleGrid.iconSize) / 2,
               y: rect.midY - HostGroupTitleGrid.iconSize / 2,
               width: HostGroupTitleGrid.iconSize, height: HostGroupTitleGrid.iconSize)
    }
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var title = super.titleRect(forBounds: rect)
        title.origin.x = rect.minX + HostGroupTitleGrid.textLeading
        title.size.width = max(0, rect.maxX - title.minX)
        return title
    }
}

/// A group header is both a disclosure action and a drag source. Keep mouse
/// tracking together so the disclosure button cannot consume a group drag.
struct HostGroupTitle: NSViewRepresentable {
    let group: HostGroup
    let appearance: HostGroupAppearance
    let expanded: Bool
    let toggle: () -> Void

    func makeNSView(context: Context) -> HostGroupTitleButton { HostGroupTitleButton() }
    func updateNSView(_ button: HostGroupTitleButton, context: Context) {
        button.title = group.title
        button.dragToken = "group:" + (group.name ?? "")
        button.onActivate = toggle
        let symbol = NSImage(systemSymbolName: appearance.symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        button.image = symbol?.withSymbolConfiguration(.init(paletteColors: [GroupAppearanceColor.native(appearance.resolvedColorHex)]))
        button.setAccessibilityLabel(group.title)
        button.setAccessibilityValue(T(expanded ? "已展开" : "已折叠"))
        button.setAccessibilityIdentifier("Termvia.HostGroup." + group.id)
    }
}

class HostGroupTitleButton: NSButton, NSDraggingSource {
    var dragToken = "group:"
    var onActivate: (() -> Void)?
    private weak var activeDragArea: HostGroupDragContainer?
    var canDragGroup: Bool { dragToken.hasPrefix("group:") && dragToken.count > 6 }
    var draggingWriter: NSPasteboardWriting? {
        guard canDragGroup else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(dragToken.dropFirst(6)), forType: HostGroupDragContainer.pasteboardType)
        return item
    }

    init() {
        super.init(frame: .zero)
        cell = HostGroupTitleCell(textCell: "")
        setButtonType(.momentaryChange)
        isBordered = false; alignment = .left
        imagePosition = .imageLeading; imageHugsTitle = false
        imageScaling = .scaleProportionallyDown
        font = .systemFont(ofSize: NSFont.systemFontSize)
        lineBreakMode = .byTruncatingTail
        target = self; action = #selector(activateGroup)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var mouseDownCanMoveWindow: Bool { false }
    @objc private func activateGroup() { onActivate?() }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        if event.modifierFlags.contains(.control) { super.mouseDown(with: event); return }
        let start = event.locationInWindow
        highlight(true)
        defer { highlight(false) }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp {
                if bounds.contains(convert(next.locationInWindow, from: nil)), let action { sendAction(action, to: target) }
                return
            }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) >= 3 {
                highlight(false)
                if canDragGroup { startGroupDrag(with: event) }
                return
            }
        }
    }
    /// A compact group card leaves the insertion marker visible even for large groups.
    func dragPreview() -> (frame: NSRect, image: NSImage) {
        let previewFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let width = min(200, max(72, (title as NSString).size(withAttributes: [.font: previewFont]).width + 40))
        let size = NSSize(width: width, height: 28)
        var background = NSColor.windowBackgroundColor, foreground = NSColor.labelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .windowBackgroundColor
            foreground = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        let icon = image, label = title
        let preview = NSImage(size: size, flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            shape.addClip(); background.setFill(); shape.fill()
            icon?.draw(in: NSRect(x: 8, y: 7, width: 14, height: 14))
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            (label as NSString).draw(in: NSRect(x: 28, y: 6, width: rect.width - 36, height: 17),
                                     withAttributes: [.font: previewFont, .foregroundColor: foreground, .paragraphStyle: paragraph])
            return true
        }
        return (NSRect(origin: bounds.origin, size: size), preview)
    }
    func startGroupDrag(with event: NSEvent) {
        guard let writer = draggingWriter else { return }
        let item = NSDraggingItem(pasteboardWriter: writer), preview = dragPreview()
        var ancestor = superview
        while let view = ancestor {
            if let area = view as? HostGroupDragContainer { activeDragArea = area; break }
            ancestor = view.superview
        }
        let point = convert(event.locationInWindow, from: nil)
        let frame = NSRect(x: point.x - 14, y: point.y - 14, width: preview.frame.width, height: preview.frame.height)
        item.setDraggingFrame(frame, contents: preview.image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.draggingFormation = .none
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    func positionDraggingItem(_ item: NSDraggingItem, at screenPoint: NSPoint) {
        item.draggingFrame.origin = NSPoint(x: screenPoint.x - 14, y: screenPoint.y - 14)
    }
    private func followPointer(_ session: NSDraggingSession, at screenPoint: NSPoint) {
        // A nil view makes the dragging frame use screen coordinates, independent
        // of sidebar scrolling or the source row's position in its window.
        session.enumerateDraggingItems(options: [], for: nil, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
            self.positionDraggingItem(item, at: screenPoint)
        }
    }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        activeDragArea?.beginGroupDrag(String(dragToken.dropFirst(6)))
        followPointer(session, at: screenPoint)
    }
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) { followPointer(session, at: session.draggingLocation) }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        activeDragArea?.endGroupDrag(); activeDragArea = nil
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        canDragGroup && context == .withinApplication ? .move : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
