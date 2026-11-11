import AppKit

/// Let AppKit render its insertion feedback, with the same table style as the
/// host list. This passive table never owns sidebar selection or input.
final class SidebarInsertionFeedback: NSTableView, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var isActive = false
    init() {
        super.init(frame: .zero)
        headerView = nil; backgroundColor = .clear
        selectionHighlightStyle = .none; focusRingType = .none
        columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        intercellSpacing = .zero; rowHeight = 12
        addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("InsertionFeedback")))
        dataSource = self; delegate = self
        setAccessibilityHidden(true)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateDraggingItemsForDrag(_ sender: NSDraggingInfo?) {} // Feedback must not replace the source card.
    func numberOfRows(in tableView: NSTableView) -> Int { 2 }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 12 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        setDropRow(1, dropOperation: .above)
        return info.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }
    func position(at point: NSPoint, width: CGFloat, style: NSTableView.Style) {
        let needsReload = self.style != style || frame.width != width || numberOfRows != 2
        if self.style != style { self.style = style }
        frame = NSRect(x: point.x, y: point.y - 12, width: width, height: 24)
        if tableColumns.first?.width != width { tableColumns.first?.width = width }
        if needsReload { reloadData() }
        layoutSubtreeIfNeeded()
        let lineY = rect(ofRow: 1).minY
        frame.origin.y = point.y + lineY - frame.height
        isHidden = !isActive
    }
    func show(at point: NSPoint, width: CGFloat, style: NSTableView.Style, dragging info: NSDraggingInfo) {
        isActive = true
        position(at: point, width: width, style: style)
        _ = draggingEntered(info)
        setDropRow(1, dropOperation: .above)
        needsDisplay = true
    }
    func clear() { draggingExited(nil); isActive = false; isHidden = true }
}
