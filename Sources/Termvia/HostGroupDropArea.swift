import AppKit
import SwiftUI

/// Native host rows and group cards share a validated destination. Group cards
/// use a private payload and group boundaries; hosts use legal row boundaries.
struct HostGroupDropArea<Content: View>: NSViewRepresentable {
    let rows: [HostSidebarRow]
    let move: (String, String?) -> Bool
    let moveHost: (UUID, Int) -> Bool
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> HostGroupDragContainer {
        let view = HostGroupDragContainer(content: AnyView(content().environment(\.locale, context.environment.locale).environment(\.colorScheme, context.environment.colorScheme)))
        view.rows = rows; view.move = move; view.moveHost = moveHost
        return view
    }
    func updateNSView(_ view: HostGroupDragContainer, context: Context) {
        view.rows = rows; view.move = move; view.moveHost = moveHost
        view.host.rootView = AnyView(content().environment(\.locale, context.environment.locale).environment(\.colorScheme, context.environment.colorScheme))
    }
}

final class HostGroupDragContainer: NSView {
    static let pasteboardType = NSPasteboard.PasteboardType("app.termvia.host-group")
    struct Boundary { let before: String?; let y: CGFloat }
    let host: NSHostingView<AnyView>
    var rows: [HostSidebarRow] = []
    var move: ((String, String?) -> Bool)?
    var moveHost: ((UUID, Int) -> Bool)?
    private let sourceFeedback = SidebarInsertionFeedback()
    private let insertionFeedback = SidebarInsertionFeedback()
    private(set) var sourceGroup: String?
    private(set) var nativeDropRow: Int?
    private(set) var dropBoundary: Boundary?
    private(set) var hostDropIndex: Int?

    init(content: AnyView) {
        host = NSHostingView(rootView: content)
        super.init(frame: .zero)
        host.sizingOptions = []; host.autoresizingMask = [.width, .height]
        addSubview(host)
        addSubview(sourceFeedback); addSubview(insertionFeedback)
        registerForDraggedTypes([Self.pasteboardType, .string])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() { super.layout(); host.frame = bounds; restoreSourceFeedback() }
    var table: NSTableView? {
        func find(_ view: NSView) -> NSTableView? {
            (view as? NSTableView) ?? view.subviews.lazy.compactMap(find).first
        }
        return find(host)
    }
    func boundaries(in table: NSTableView) -> [Boundary] {
        guard table.numberOfRows == rows.count else { return [] }
        var boundaries: [Boundary] = []
        for (index, row) in rows.enumerated() {
            if case .group(let group) = row, let name = group.name {
                boundaries.append(Boundary(before: name, y: table.rect(ofRow: index).minY))
            }
        }
        if !boundaries.isEmpty, table.numberOfRows > 0 {
            boundaries.append(Boundary(before: nil, y: table.rect(ofRow: table.numberOfRows - 1).maxY))
        }
        return boundaries
    }
    private func source(_ sender: NSDraggingInfo) -> String? {
        guard let name = sender.draggingPasteboard.string(forType: Self.pasteboardType), !name.isEmpty,
              rows.contains(where: { if case .group(let group) = $0 { return group.name == name }; return false }) else { return nil }
        return name
    }
    private func hostID(_ sender: NSDraggingInfo) -> UUID? {
        guard let token = sender.draggingPasteboard.string(forType: .string), token.hasPrefix("host:"),
              let id = UUID(uuidString: String(token.dropFirst(5))),
              rows.contains(where: { if case .host(let host, _) = $0 { return host.id == id }; return false }) else { return nil }
        return id
    }
    func hostInsertionIndex(at point: NSPoint, in table: NSTableView) -> Int? {
        guard table.numberOfRows == rows.count, !rows.isEmpty else { return nil }
        let row = table.row(at: NSPoint(x: table.bounds.midX, y: point.y))
        let index: Int
        if row >= 0 { index = point.y < table.rect(ofRow: row).midY ? row : row + 1 }
        else { index = point.y < table.rect(ofRow: 0).minY ? 0 : rows.count }
        if index == 0, case .group(let first) = rows[0], first.name == nil { return nil }
        return index
    }
    func beginGroupDrag(_ name: String) {
        guard !name.isEmpty, rows.contains(where: { if case .group(let group) = $0 { return group.name == name }; return false }) else { return }
        sourceGroup = name
        restoreSourceFeedback()
    }
    private func restoreSourceFeedback(dragging info: NSDraggingInfo? = nil) {
        guard let table, let name = sourceGroup,
              let row = rows.firstIndex(where: { if case .group(let group) = $0 { return group.name == name }; return false }) else {
            sourceFeedback.isHidden = true; return
        }
        let y = table.rect(ofRow: row).minY
        guard y >= table.visibleRect.minY, y <= table.visibleRect.maxY else { sourceFeedback.isHidden = true; return }
        let point = convert(NSPoint(x: table.bounds.minX, y: y), from: table)
        if let info { sourceFeedback.show(at: point, width: table.bounds.width, style: table.style, dragging: info) }
        else { sourceFeedback.position(at: point, width: table.bounds.width, style: table.style) }
    }
    func endGroupDrag() {
        sourceGroup = nil
        sourceFeedback.clear()
        clearBoundary()
    }
    private func clearBoundary() {
        dropBoundary = nil; hostDropIndex = nil; nativeDropRow = nil
        insertionFeedback.clear()
        restoreSourceFeedback()
    }
    private func showInsertion(at index: Int, in table: NSTableView, dragging info: NSDraggingInfo) {
        nativeDropRow = index
        let y = index < rows.count ? table.rect(ofRow: index).minY : table.rect(ofRow: rows.count - 1).maxY
        let local = convert(NSPoint(x: table.bounds.minX, y: y), from: table)
        insertionFeedback.show(at: local, width: table.bounds.width, style: table.style, dragging: info)
        restoreSourceFeedback(dragging: info)
    }
    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let table, source(sender) != nil || hostID(sender) != nil else { clearBoundary(); return [] }
        if let name = source(sender) { beginGroupDrag(name) }
        // Keep long lists scrollable while the whole block is being dragged.
        if let clip = table.enclosingScrollView?.contentView {
            let point = clip.convert(sender.draggingLocation, from: nil)
            if point.y < clip.bounds.minY + 24 { table.scroll(NSPoint(x: 0, y: max(0, clip.bounds.minY - 8))) }
            else if point.y > clip.bounds.maxY - 24 { table.scroll(NSPoint(x: 0, y: clip.bounds.minY + 8)) }
        }
        let point = table.convert(sender.draggingLocation, from: nil)
        if hostID(sender) != nil {
            let operation: NSDragOperation = sender.draggingSourceOperationMask.contains(.copy) ? .copy : .move
            guard sender.draggingSourceOperationMask.contains(operation), let index = hostInsertionIndex(at: point, in: table) else {
                clearBoundary(); return []
            }
            dropBoundary = nil; hostDropIndex = index
            showInsertion(at: index, in: table, dragging: sender)
            return operation
        }
        guard sender.draggingSourceOperationMask.contains(.move), source(sender) != nil else { clearBoundary(); return [] }
        guard let boundary = boundaries(in: table).min(by: { abs($0.y - point.y) < abs($1.y - point.y) }) else {
            clearBoundary(); return []
        }
        dropBoundary = boundary; hostDropIndex = nil
        let index = boundary.before.flatMap { name in rows.firstIndex { if case .group(let group) = $0 { return group.name == name }; return false } } ?? rows.count
        showInsertion(at: index, in: table, dragging: sender)
        return .move
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearBoundary() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !update(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { endGroupDrag() }
        guard !update(sender).isEmpty else { return false }
        if let id = hostID(sender), let index = hostDropIndex { return moveHost?(id, index) ?? false }
        guard let source = source(sender), let boundary = dropBoundary else { return false }
        if boundary.before == source { return true }
        return move?(source, boundary.before) ?? false
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { endGroupDrag() }
}
