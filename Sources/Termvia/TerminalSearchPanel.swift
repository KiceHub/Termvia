import AppKit
import SwiftTerm
import TermviaCore

extension AppModel {
    func showTerminalSearch(for tab: Session) {
        guard !tab.isStartPage, sessions.contains(where: { $0 === tab }),
              let workspaceWindow, workspaceWindow.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        selected = tab.id
        let panel = terminalSearch ?? TerminalSearchPanel()
        terminalSearch = panel
        let session = tabTerminal(tab)
        let key = Self.workspaceKey(for: session)
        panel.present(for: session.terminal, in: workspaceWindow, options: findOptions(for: key)) { [weak self] options in
            self?.setFindOptions(options, for: key)
        }
    }
}

private final class TerminalSearchFieldCell: NSSearchFieldCell {
    static let counterWidth: CGFloat = 94
    static let counterInset: CGFloat = 10

    override func searchTextRect(forBounds bounds: NSRect) -> NSRect {
        var text = super.searchTextRect(forBounds: bounds)
        let counterStart = bounds.maxX - Self.counterInset - Self.counterWidth
        text.size.width = max(0, min(text.maxX, counterStart - 4) - text.minX)
        return text
    }
}

private final class TerminalSearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { TerminalSearchFieldCell.self }
        set { super.cellClass = newValue }
    }
}

/// A modeless child window keeps the terminal visible while its results are selected.
@MainActor final class TerminalSearchPanel: NSPanel, NSSearchFieldDelegate {
    private(set) weak var terminal: ThemedTerminalView?
    private let field = TerminalSearchField()
    private let navigation = NSSegmentedControl()
    private let replacement = NSTextField()
    private let replaceActions = NSSegmentedControl()
    private let replaceRow = NSStackView()
    private weak var editor: NSTextView?
    private var options = FindOptions()
    private var onOptionsChanged: ((FindOptions) -> Void)?
    private var editorFormat: (() -> EditorReplacementFormat)?
    private var onReplacementFailure: ((Error) -> Void)?
    private var editorMatches: EditorFindMatches?
    private var editorSearch: Task<Void, Never>?
    private var editorReplacement: Task<Void, Never>?
    private var terminalMatches: TerminalFindMatches?
    private var terminalCursor: TerminalFindMatches.Cursor?
    private var terminalSearch: Task<Void, Never>?
    private var replaceMode = false
    private let closeButton = NSButton()
    private let counter = NSTextField(labelWithString: "0/0")
    private var pendingSearch: Task<Void, Never>?
    private var searchedQuery = ""
    private var match = (index: 0, total: 0)

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        let frame = NSRect(x: 0, y: 0, width: 354, height: 42)
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior.insert(.fullScreenAuxiliary)
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        field.delegate = self
        field.setAccessibilityIdentifier("Termvia.TerminalSearch.Query")
        navigation.target = self
        navigation.action = #selector(navigate(_:))
        replaceActions.target = self
        replaceActions.action = #selector(replace(_:))
        for control in [navigation, replaceActions] {
            control.segmentCount = 2
            control.trackingMode = .momentary
            control.segmentStyle = .rounded
            control.controlSize = .small
            control.setContentHuggingPriority(.required, for: .horizontal)
        }
        replacement.setContentHuggingPriority(.defaultLow, for: .horizontal)
        replacement.isAutomaticTextCompletionEnabled = false
        replacement.cell?.sendsActionOnEndEditing = false
        replaceRow.addArrangedSubview(replacement)
        replaceRow.addArrangedSubview(replaceActions)
        replaceRow.spacing = 6
        replaceRow.alignment = .centerY
        replaceRow.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(performClose(_:))
        counter.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        counter.textColor = .secondaryLabelColor
        counter.alignment = .right
        counter.setAccessibilityIdentifier("Termvia.TerminalSearch.Count")
        counter.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(counter)

        let controls = NSStackView(views: [field, navigation, closeButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.distribution = .fill
        controls.spacing = 6
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let content = NSView(frame: frame)
        let rows = NSStackView(views: [controls, replaceRow])
        rows.orientation = .vertical
        rows.alignment = .centerX
        rows.spacing = 8
        rows.detachesHiddenViews = true
        rows.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            controls.widthAnchor.constraint(equalToConstant: frame.width - 16),
            replaceRow.widthAnchor.constraint(equalToConstant: frame.width - 16),
            counter.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            counter.rightAnchor.constraint(equalTo: field.rightAnchor, constant: -TerminalSearchFieldCell.counterInset),
            counter.widthAnchor.constraint(equalToConstant: TerminalSearchFieldCell.counterWidth)
        ])
        let glass = NSGlassEffectView(frame: frame)
        glass.style = .regular
        glass.cornerRadius = frame.height / 2
        glass.contentView = content
        contentView = glass
        initialFirstResponder = field
        localize()
    }

    func localize() {
        field.placeholderString = T("查找")
        for (index, symbol, title) in [(0, "chevron.left", T("上一个匹配项")), (1, "chevron.right", T("下一个匹配项"))] {
            navigation.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: title), forSegment: index)
            navigation.setToolTip(title, forSegment: index)
        }
        replaceActions.setLabel(T("替换"), forSegment: 0)
        replaceActions.setLabel(T("全部"), forSegment: 1)
        replacement.placeholderString = T("替换")
        replacement.setAccessibilityLabel(T("替换"))
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .small
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: T("关闭"))
        closeButton.imagePosition = .imageOnly
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.toolTip = T("关闭")
        closeButton.setAccessibilityLabel(T("关闭"))
        updateOptionsMenu()
        updateControls()
    }

    private func updateOptionsMenu() {
        title = T(editor == nil ? "终端查找" : "查找")
        field.setAccessibilityLabel(T(editor == nil ? "查找终端文本" : "查找"))
        let menu = NSMenu()
        menu.autoenablesItems = false
        let items = [(T("区分大小写"), options.caseSensitive), (T("全字符匹配"), options.wholeWord),
                     (T("循环查找"), options.wraps), (T("正则表达式"), options.regex)]
        for (index, entry) in items.enumerated() {
            if index == 3 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: entry.0, action: #selector(toggleOption(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = entry.1 ? .on : .off
            item.isEnabled = onOptionsChanged != nil
            menu.addItem(item)
        }
        if let editor {
            menu.addItem(.separator())
            let item = NSMenuItem(title: T("替换"), action: #selector(toggleOption(_:)), keyEquivalent: "")
            item.target = self
            item.tag = 4
            item.state = replaceMode ? .on : .off
            item.isEnabled = editor.isEditable
            menu.addItem(item)
        }
        field.maximumRecents = 0
        field.searchMenuTemplate = menu
        if let cell = field.cell as? NSSearchFieldCell {
            let symbol = options.regex ? "function" : "magnifyingglass"
            cell.searchButtonCell?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: T("高级查找"))
        }
        field.needsDisplay = true
    }

    @objc private func toggleOption(_ item: NSMenuItem) {
        if item.tag == 4 {
            guard editor?.isEditable == true else { return }
            setReplaceMode(!replaceMode)
            updateOptionsMenu()
            return
        }
        guard let onOptionsChanged else { return }
        switch item.tag {
        case 0: options.caseSensitive.toggle()
        case 1: options.wholeWord.toggle()
        case 2: options.wraps.toggle()
        case 3: options.regex.toggle()
        default: return
        }
        onOptionsChanged(options)
        updateOptionsMenu()
        if item.tag == 2 { updateControls() }
        else {
            find(forward: false, reset: true)
        }
    }

    private func setReplaceMode(_ enabled: Bool) {
        replaceMode = enabled
        replaceRow.isHidden = !enabled
        let height: CGFloat = enabled ? 75 : 42
        var nextFrame = frame
        nextFrame.origin.y = frame.maxY - height
        nextFrame.size.height = height
        setFrame(nextFrame, display: isVisible)
        if enabled { makeFirstResponder(replacement) }
        else if isVisible { makeFirstResponder(field) }
    }

    func present(for terminal: ThemedTerminalView, in workspace: NSWindow, options: FindOptions,
                 onOptionsChanged: @escaping (FindOptions) -> Void) {
        if self.terminal !== terminal || parent !== workspace { close() }
        self.terminal = terminal
        self.options = options
        self.onOptionsChanged = onOptionsChanged
        present(in: workspace)
    }

    func present(for editor: NSTextView, in window: NSWindow, options: FindOptions,
                 format: (() -> EditorReplacementFormat)? = nil, onReplacementFailure: ((Error) -> Void)? = nil,
                 onOptionsChanged: @escaping (FindOptions) -> Void) {
        if self.editor !== editor || parent !== window { close() }
        self.editor = editor
        self.options = options
        self.onOptionsChanged = onOptionsChanged
        editorFormat = format
        self.onReplacementFailure = onReplacementFailure
        present(in: window)
    }

    private func present(in workspace: NSWindow) {
        updateOptionsMenu()
        if parent !== workspace {
            let area = workspace.convertToScreen(workspace.contentLayoutRect)
            let visible = workspace.screen?.visibleFrame ?? workspace.frame
            let x = max(visible.minX, min(area.maxX, visible.maxX) - frame.width - 16)
            let y = max(visible.minY, min(area.maxY, visible.maxY) - frame.height - 12)
            setFrameOrigin(NSPoint(x: x, y: y))
            workspace.addChildWindow(self, ordered: .above)
        }
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        field.selectText(nil)
    }

    override func close() {
        guard terminal != nil || editor != nil || parent != nil else { return }
        pendingSearch?.cancel()
        pendingSearch = nil
        editorSearch?.cancel()
        editorSearch = nil
        editorReplacement?.cancel()
        editorReplacement = nil
        editorMatches = nil
        terminalSearch?.cancel()
        terminalSearch = nil
        terminalMatches = nil
        terminalCursor = nil
        editorFormat = nil
        onReplacementFailure = nil
        terminal = nil
        editor = nil
        onOptionsChanged = nil
        parent?.removeChildWindow(self)
        super.close()
        field.stringValue = ""
        replacement.stringValue = ""
        setReplaceMode(false)
        searchedQuery = ""
        match = (0, 0)
        updateControls()
    }

    override func performClose(_ sender: Any?) { close() }
    override func cancelOperation(_ sender: Any?) { close() }

    func controlTextDidChange(_ notification: Notification) {
        pendingSearch?.cancel()
        pendingSearch = nil
        if editor != nil { invalidateEditorResults() }
        if terminal != nil {
            terminalSearch?.cancel()
            terminalSearch = nil
        }
        guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if field.stringValue.isEmpty {
            find(forward: false, reset: true)
        } else {
            pendingSearch = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                self?.find(forward: false, reset: true)
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        case #selector(NSResponder.insertNewline(_:)):
            find(forward: NSApp.currentEvent?.modifierFlags.contains(.shift) != true)
        default:
            return false
        }
        return true
    }

    @objc private func navigate(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0 else { return }
        find(forward: sender.selectedSegment == 1)
    }

    private func canNavigate(forward: Bool) -> Bool {
        if match.index == 0 {
            guard let editor, let results = editorMatches else { return true }
            guard match.total > 0 else { return false }
            if options.wraps { return true }
            let position = results.firstMatch(atOrAfter: editor.selectedRange().location)
            return forward ? position < match.total : position > 0
        }
        return options.wraps || (forward ? match.index < match.total : match.index > 1)
    }

    private func find(forward: Bool, reset: Bool = false) {
        pendingSearch?.cancel()
        pendingSearch = nil
        let query = field.stringValue
        let sameQuery = (searchedQuery as NSString).isEqual(to: query)
        if let editor {
            if !reset, sameQuery, !canNavigate(forward: forward) { return }
            find(in: editor, query: query, forward: reset || forward, reset: reset)
            return
        }
        guard let terminal else { return }
        terminalSearch?.cancel()
        let useCache = !reset && sameQuery
        if query.isEmpty {
            terminalMatches = nil
            terminalCursor = nil
            if !searchedQuery.isEmpty { terminal.selectNone() }
            searchedQuery = ""
            match = (0, 0)
            updateControls()
            return
        }
        let options = options
        let cached = useCache ? terminalMatches : nil
        let previous = useCache ? terminalCursor : nil
        let work = Task.detached(priority: .userInitiated) { [weak terminal] in
            guard let terminal else { return nil as (TerminalFindMatches, TerminalFindMatches.Cursor?)? }
            // Output can trim the first batch during inspection. Retry against
            // its new retained range once without blocking the main actor.
            for _ in 0..<2 {
                guard !Task.isCancelled, let state = TerminalFindMatches.State(in: terminal) else { return nil }
                let sameIndex = cached?.state == state
                guard let results = sameIndex ? cached : TerminalFindMatches(in: terminal, state: state, query: query, options: options) else { continue }
                let cursor = results.move(in: terminal, from: previous, sameIndex: sameIndex, forward: forward, wraps: options.wraps)
                // Repaints can move or replace a live-screen match while the
                // older scrollback is being indexed. Retry live results once.
                if (cursor?.location.end.row ?? state.liveTopRow) >= state.liveTopRow,
                   TerminalFindMatches.State(in: terminal) != state { continue }
                return (results, cursor)
            }
            return nil
        }
        terminalSearch = Task { [weak self, weak terminal] in
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let self, let terminal, self.terminal === terminal,
                  (query as NSString).isEqual(to: field.stringValue) else { return }
            terminalSearch = nil
            guard let (results, cursor) = result else { return }
            terminalMatches = results
            terminalCursor = if let cursor, select(cursor.location, in: terminal, state: results.state) { cursor } else { nil }
            if terminalCursor == nil { terminal.selectNone() }
            match = (terminalCursor?.index ?? 0, results.total)
            searchedQuery = query
            updateControls()
        }
    }

    private func select(_ location: TerminalFindMatches.Location, in terminal: ThemedTerminalView,
                        state: TerminalFindMatches.State) -> Bool {
        // Convert just before selecting so trims can move the origin without
        // changing the absolute identity of a retained match.
        guard location.stillMatches(in: terminal, state: state),
              let bounds = terminal.terminalContentSnapshot(region: .rows(Int.min..<Int.min)),
              let end = terminal.terminalContentSnapshot(region: .rows(Int.max..<Int.max)),
              bounds.dimensions == state.dimensions, end.dimensions == state.dimensions,
              (bounds.bufferKind == .alt) == state.alternate, end.bufferKind == bounds.bufferKind else { return false }
        let first = bounds.capturedRange.lowerBound
        guard location.start.row >= first, location.end.row < end.capturedRange.upperBound else { return false }
        let start = Position(col: location.start.col, row: location.start.row - first)
        let finish = Position(col: location.end.col, row: location.end.row - first)
        terminal.setSelectionRange(start: start, end: finish)
        // SwiftTerm takes its own lock for coordinate selection, so bracket
        // it with checks in case its parsing thread repaints or trims a row.
        guard let selectedBounds = terminal.terminalContentSnapshot(region: .rows(Int.min..<Int.min)),
              selectedBounds.capturedRange.lowerBound == first,
              location.stillMatches(in: terminal, state: state) else { return false }
        if !state.alternate {
            let scrollback = max(0, end.liveTopRow - first)
            let top = Int((terminal.scrollPosition * Double(scrollback)).rounded())
            if !(top..<(top + state.dimensions.rows)).contains(start.row) {
                terminal.scrollTo(row: start.row - state.dimensions.rows / 2)
            }
        }
        return true
    }

    func editorTextChanged() {
        guard let editor else { return }
        if let item = field.searchMenuTemplate?.items.last, item.tag == 4, item.isEnabled != editor.isEditable {
            if !editor.isEditable, replaceMode { setReplaceMode(false) }
            updateOptionsMenu()
        }
        guard !field.stringValue.isEmpty else { return }
        invalidateEditorResults()
        pendingSearch?.cancel()
        pendingSearch = Task { [weak self, weak editor] in
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            guard let self, let editor, self.editor === editor else { return }
            self.pendingSearch = nil
            self.find(in: editor, query: self.field.stringValue, forward: true, reset: true, selectMatch: false)
        }
    }

    func editorSelectionChanged() {
        guard let editor, let results = editorMatches else { return }
        if match.index > 0 {
            guard editor.selectedRange() != results.ranges[match.index - 1] else { return }
            match.index = 0
        } else if options.wraps { return }
        updateControls()
    }

    private func invalidateEditorResults() {
        editorSearch?.cancel()
        editorSearch = nil
        editorReplacement?.cancel()
        editorReplacement = nil
        editorMatches = nil
        match = (0, 0)
        searchedQuery = ""
        updateControls()
    }

    private func find(in editor: NSTextView, query: String, forward: Bool, reset: Bool, selectMatch: Bool = true) {
        // Editing, refreshing, and encoding changes invalidate the cache
        // through editorTextChanged. Navigating it needn't copy the buffer.
        if let results = editorMatches, results.matches(query: query, options: options) {
            select(in: editor, results: results, forward: forward, reset: reset, selectMatch: selectMatch)
            return
        }
        invalidateEditorResults()
        guard !query.isEmpty else { return }
        let text = editor.string
        let options = options
        let work = Task.detached(priority: .userInitiated) { EditorFindMatches(text: text, query: query, options: options) }
        editorSearch = Task { [weak self, weak editor] in
            let results = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let self, let editor, self.editor === editor,
                  results.isCurrent(text: editor.string, query: self.field.stringValue, options: self.options) else { return }
            self.editorMatches = results
            self.select(in: editor, results: results, forward: forward, reset: true, selectMatch: selectMatch)
        }
    }

    private func select(in editor: NSTextView, results: EditorFindMatches, forward: Bool, reset: Bool, selectMatch: Bool) {
        let total = results.ranges.count
        var nextIndex: Int?
        if total > 0, selectMatch {
            let range = editor.selectedRange()
            let exactMatch = !reset && match.index > 0 && match.index <= total
                && results.ranges[match.index - 1] == range
            let position = exactMatch ? match.index - 1 : results.firstMatch(atOrAfter: range.location)
            let next = position + (forward ? (exactMatch ? 1 : 0) : -1)
            if results.ranges.indices.contains(next) { nextIndex = next }
            else if options.wraps { nextIndex = forward ? 0 : total - 1 }
        }
        match = (nextIndex.map { $0 + 1 } ?? 0, total)
        if let nextIndex {
            let location = results.ranges[nextIndex]
            editor.setSelectedRange(location)
            editor.scrollRangeToVisible(location)
            editor.showFindIndicator(for: location)
        }
        searchedQuery = results.query
        updateControls()
    }

    @objc private func replace(_ sender: NSSegmentedControl) {
        guard parent?.attachedSheet == nil, NSApp.modalWindow == nil,
              let editor, editor.isEditable, let results = editorMatches,
              editorReplacement == nil,
              results.isCurrent(text: editor.string, query: field.stringValue, options: options),
              match.total > 0, sender.selectedSegment >= 0 else { return }
        let all = sender.selectedSegment == 1
        guard all || match.index > 0 else { return }
        let current = all ? nil : match.index - 1
        let range = current.map { results.ranges[$0] } ?? NSRange(location: 0, length: results.text.utf16.count)
        if !all, range != editor.selectedRange() { return }
        let template = replacement.stringValue
        let format = editorFormat?() ?? .init()
        let work = Task.detached(priority: .userInitiated) { try results.replacement(template, at: current, format: format) }
        editorReplacement = Task { [weak self, weak editor] in
            let result = await withTaskCancellationHandler { await work.result } onCancel: { work.cancel() }
            guard !Task.isCancelled, let self else { return }
            self.editorReplacement = nil
            self.updateControls()
            guard let editor, self.editor === editor, editor.isEditable, self.parent?.attachedSheet == nil, NSApp.modalWindow == nil,
                  results.isCurrent(text: editor.string, query: self.field.stringValue, options: self.options),
                  format == (self.editorFormat?() ?? .init()), all || range == editor.selectedRange() else { return }
            switch result {
            case .success(let value): self.applyReplacement(value, in: editor, range: range, all: all)
            case .failure(let error):
                if let onReplacementFailure = self.onReplacementFailure { onReplacementFailure(error) }
                else { NSSound.beep() }
            }
        }
        updateControls()
    }

    private func applyReplacement(_ value: String, in editor: NSTextView, range: NSRange, all: Bool) {
        guard editor.shouldChangeText(in: range, replacementString: value) else { return }
        let caret = all ? min(editor.selectedRange().location, value.utf16.count) : range.location + value.utf16.count
        editor.textStorage?.replaceCharacters(in: range, with: value)
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        editor.didChangeText()
        find(forward: true, reset: true)
    }

    private func updateControls() {
        navigation.setEnabled(!searchedQuery.isEmpty && canNavigate(forward: false), forSegment: 0)
        navigation.setEnabled(!searchedQuery.isEmpty && (terminal != nil || canNavigate(forward: true)), forSegment: 1)
        let canReplace = editor?.isEditable == true && editorReplacement == nil
        replaceActions.setEnabled(canReplace && match.index > 0, forSegment: 0)
        replaceActions.setEnabled(canReplace && match.total > 0, forSegment: 1)
        counter.stringValue = "\(match.index)/\(match.total)"
    }
}
