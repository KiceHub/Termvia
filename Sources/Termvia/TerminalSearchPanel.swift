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
    private var editorMatches: EditorFindMatches?
    private var editorSearch: Task<Void, Never>?
    private var editorReplacement: Task<Void, Never>?
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
            terminal?.clearSearch()
            searchedQuery = ""
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
                 onOptionsChanged: @escaping (FindOptions) -> Void) {
        if self.editor !== editor || parent !== window { close() }
        self.editor = editor
        self.options = options
        self.onOptionsChanged = onOptionsChanged
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

    private func literalCanOverlap(_ query: String) -> Bool {
        let characters = Array(options.caseSensitive ? query : query.folding(options: .caseInsensitive, locale: nil))
        guard characters.count > 1 else { return false }
        // Track the longest proper prefix which is also a suffix. Only those
        // literals can produce a reverse match absent from the forward count.
        var prefixLengths = [Int](repeating: 0, count: characters.count)
        var length = 0
        for index in 1..<characters.count {
            while length > 0, characters[index] != characters[length] {
                length = prefixLengths[length - 1]
            }
            if characters[index] == characters[length] { length += 1 }
            prefixLengths[index] = length
        }
        return length > 0
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
        // SwiftTerm's backward literal search can select overlaps that its
        // forward count skips. An escaped pattern uses nonoverlapping matches
        // in both directions, while keeping user text literal.
        let escape = !options.regex && literalCanOverlap(query)
        let pattern = escape ? NSRegularExpression.escapedPattern(for: query) : query
        let search = SearchOptions(caseSensitive: options.caseSensitive, regex: options.regex || escape, wholeWord: options.wholeWord)
        if !reset, sameQuery, !canNavigate(forward: forward) {
            guard forward else { return }
            let current = terminal.searchMatchSummary(pattern, options: search, limit: .max)
            // Output may have appended matches since we reached the end.
            guard current.index == 0, current.total > match.total else { return }
        }
        let found: Bool
        if query.isEmpty {
            if !searchedQuery.isEmpty { terminal.clearSearch() }
            found = false
        } else if forward {
            found = terminal.findNext(pattern, options: search)
        } else {
            // SwiftTerm can exhaust the last row before wrapping a reverse search.
            let shouldWrap = options.wraps && match.total > 0 && sameQuery
            found = terminal.findPrevious(pattern, options: search) || (shouldWrap && terminal.findPrevious(pattern, options: search))
        }
        match = found ? terminal.searchMatchSummary(pattern, options: search, limit: .max) : (0, 0)
        if found, match.index == 0 {
            // SwiftTerm enumeration skips overlaps that reverse search can select.
            terminal.clearSearch()
            match = terminal.findNext(pattern, options: search) ? terminal.searchMatchSummary(pattern, options: search, limit: .max) : (0, 0)
        }
        searchedQuery = query
        updateControls()
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
        guard all || results.expandsTemplate(template) else {
            applyReplacement(template, in: editor, range: range, all: all)
            return
        }
        let work = Task.detached(priority: .userInitiated) { results.replacement(template, at: current) }
        editorReplacement = Task { [weak self, weak editor] in
            let value = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let self else { return }
            self.editorReplacement = nil
            self.updateControls()
            guard let editor, self.editor === editor, editor.isEditable, self.parent?.attachedSheet == nil, NSApp.modalWindow == nil,
                  results.isCurrent(text: editor.string, query: self.field.stringValue, options: self.options),
                  all || range == editor.selectedRange() else { return }
            self.applyReplacement(value, in: editor, range: range, all: all)
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
