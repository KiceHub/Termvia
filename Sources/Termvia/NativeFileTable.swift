import AppKit
import SwiftUI
import TermviaCore

struct NativeFileRow: Equatable {
    let id: String
    let entry: RemoteEntry
    var localURL: URL? = nil
    var sessionID: UUID? = nil
    var payload: FileDragPayload {
        if let localURL { return FileDragPayload(localPaths: [localURL.path]) }
        return FileDragPayload(sessionID: sessionID, entries: [entry])
    }
}

/// Standard AppKit file table. Its data source owns both ends of native drag
/// and drop, including the empty scroll area, independently of cell gestures.
@MainActor struct NativeFileTable: NSViewRepresentable {
    let rows: [NativeFileRow]
    @Binding var selection: Set<String>
    let ready: Bool
    let drop: ([NSItemProvider]) -> Bool
    let open: (Set<String>) -> Void
    let sort: ([(String, Bool)]) -> Void
    let menu: (Set<String>) -> AnyView
    @Environment(\.locale) private var locale

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> FileScrollView {
        context.coordinator.updating = true
        let scroll = FileScrollView()
        let table = FileTableView()
        table.autoresizingMask = []
        table.style = .plain; table.rowSizeStyle = .small
        table.allowsMultipleSelection = true; table.allowsEmptySelection = true
        table.allowsColumnReordering = false; table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.doubleClick)
        table.coordinator = context.coordinator; scroll.coordinator = context.coordinator
        for (key, title, width, minimum) in [("name", "名称", 230.0, 110.0), ("size", "大小", 75.0, 50.0), ("date", "修改时间", 155.0, 155.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = T(title); column.width = width; column.minWidth = minimum
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        let types = [NSPasteboard.PasteboardType(FileDragPayload.type), .fileURL]
        table.registerForDraggedTypes(types); scroll.registerForDraggedTypes(types)
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        context.coordinator.table = table
        context.coordinator.updating = false
        return scroll
    }
    func updateNSView(_ scroll: FileScrollView, context: Context) {
        let coordinator = context.coordinator
        let localeChanged = coordinator.parent.locale != locale
        coordinator.parent = self
        guard let table = coordinator.table else { return }
        table.isEnabled = context.environment.isEnabled
        for (index, key) in ["名称", "大小", "修改时间"].enumerated() { table.tableColumns[index].title = T(key) }
        table.usesAlternatingRowBackgroundColors = !rows.isEmpty
        coordinator.updating = true
        if coordinator.rows != rows || localeChanged {
            coordinator.rows = rows
            coordinator.currentIDs = Set(rows.map(\.id))
            table.reloadData()
        }
        let indexes = IndexSet(rows.indices.filter { selection.contains(rows[$0].id) })
        if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
        coordinator.updating = false
        scroll.needsLayout = true
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeFileTable
        var rows: [NativeFileRow] = []
        weak var table: NSTableView?
        var updating = false
        var currentIDs: Set<String> = []
        func tableViewColumnDidResize(_ notification: Notification) {
            guard let scroll = table?.enclosingScrollView as? FileScrollView, !scroll.arrangingColumns else { return }
            if let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn, column.identifier.rawValue == "name" { scroll.preferredNameWidth = column.width }
            scroll.tile()
        }
        private var icons: [URL: NSImage] = [:]
        private var pendingIcons: Set<URL> = []
        init(parent: NativeFileTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let key = tableColumn?.identifier.rawValue else { return nil }
            let item = rows[row], entry = item.entry
            let identifier = NSUserInterfaceItemIdentifier("Termvia.FileCell." + key)
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? FileCell) ?? FileCell(name: key == "name")
            cell.identifier = identifier; cell.rowID = item.id
            let text: String
            switch key {
            case "size": text = entry.kind == .file ? entry.size.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "—" : "—"
            case "date": text = entry.modified?.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(parent.locale)) ?? "—"
            default: text = entry.displayName
            }
            cell.textField?.stringValue = text
            cell.textField?.textColor = key == "name" ? .labelColor : .secondaryLabelColor
            cell.toolTip = key == "name" ? entry.name : text
            if key == "name" {
                cell.imageView?.image = NSImage(systemSymbolName: entry.kind == .directory ? "folder" : entry.kind == .symbolicLink ? "link" : "doc", accessibilityDescription: nil)
                if let url = item.localURL {
                    if let icon = icons[url] { cell.imageView?.image = icon }
                    else if pendingIcons.insert(url).inserted {
                        Task { [weak self, weak cell] in
                            let image = await Task.detached(priority: .utility) { NSWorkspace.shared.icon(forFile: url.path) }.value
                            guard let self else { return }
                            self.pendingIcons.remove(url)
                            guard self.currentIDs.contains(item.id) else { return }
                            if self.icons.count >= 256 { self.icons.removeAll(keepingCapacity: true) }
                            self.icons[url] = image
                            if cell?.rowID == item.id { cell?.imageView?.image = image }
                        }
                    }
                }
            }
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            parent.selection = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
        }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating else { return }
            parent.sort(tableView.sortDescriptors.compactMap { descriptor in descriptor.key.map { ($0, descriptor.ascending) } })
        }
        @objc func doubleClick() { parent.open(parent.selection) }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.ready, rows.indices.contains(row), let data = try? JSONEncoder().encode(rows[row].payload) else { return nil }
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType(FileDragPayload.type))
            if let url = rows[row].localURL { item.setString(url.absoluteString, forType: .fileURL) }
            return item
        }
        func accepts(_ info: NSDraggingInfo) -> Bool {
            let types = info.draggingPasteboard.types ?? []
            return parent.ready && (types.contains(NSPasteboard.PasteboardType(FileDragPayload.type)) || types.contains(.fileURL))
        }
        func receive(_ info: NSDraggingInfo) -> Bool {
            guard accepts(info) else { return false }
            let providers = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { item -> NSItemProvider? in
                if let data = item.data(forType: NSPasteboard.PasteboardType(FileDragPayload.type)) {
                    let provider = NSItemProvider()
                    provider.registerDataRepresentation(forTypeIdentifier: FileDragPayload.type, visibility: .all) { complete in complete(data, nil); return nil }
                    return provider
                }
                if let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL { return NSItemProvider(object: url as NSURL) }
                return nil
            }
            return !providers.isEmpty && parent.drop(providers)
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard accepts(info) else { return [] }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool { receive(info) }
        func contextMenu(_ ids: Set<String>) -> NSMenu {
            NSHostingMenu(rootView: parent.menu(ids).environment(\.locale, parent.locale))
        }
    }

    @MainActor final class FileScrollView: NSScrollView {
        weak var coordinator: Coordinator?
        var preferredNameWidth: CGFloat = 230
        private(set) var arrangingColumns = false
        override func tile() {
            guard !arrangingColumns else { return }
            arrangingColumns = true
            defer { arrangingColumns = false }
            super.tile()
            if let table = documentView as? NSTableView {
                let spacing = CGFloat(table.tableColumns.count) * table.intercellSpacing.width
                let otherWidths = table.tableColumns.dropFirst().reduce(CGFloat(0)) { $0 + $1.width }
                if let name = table.tableColumns.first {
                    name.width = max(preferredNameWidth, contentView.bounds.width - otherWidths - spacing)
                }
                let width = table.tableColumns.reduce(CGFloat(0)) { $0 + $1.width } + spacing
                let height = max(CGFloat(table.numberOfRows) * (table.rowHeight + table.intercellSpacing.height) + 1, contentView.bounds.height)
                let size = NSSize(width: max(contentView.bounds.width, width), height: height)
                if table.frame.size != size { table.setFrameSize(size) }

            }
        }
        override func menu(for event: NSEvent) -> NSMenu? { coordinator?.contextMenu([]) }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { coordinator?.accepts(sender) == true ? .copy : [] }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { coordinator?.accepts(sender) == true }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { coordinator?.receive(sender) == true }
    }
    @MainActor final class FileTableView: NSTableView {
        weak var coordinator: Coordinator?
        override func menu(for event: NSEvent) -> NSMenu? {
            let row = row(at: convert(event.locationInWindow, from: nil))
            if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            let ids = row >= 0 ? Set(selectedRowIndexes.compactMap { coordinator?.rows.indices.contains($0) == true ? coordinator?.rows[$0].id : nil }) : []
            return coordinator?.contextMenu(ids)
        }
    }
    @MainActor final class FileCell: NSTableCellView {
        var rowID = ""
        init(name: Bool) {
            super.init(frame: .zero)
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = name ? .byTruncatingMiddle : .byClipping; text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textField = text
            let stack = NSStackView(); stack.orientation = .horizontal; stack.spacing = 6
            if name {
                let icon = NSImageView(); icon.imageScaling = .scaleProportionallyDown
                icon.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16)])
                imageView = icon; stack.addArrangedSubview(icon)
            }
            stack.addArrangedSubview(text); stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2), stack.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }
}
