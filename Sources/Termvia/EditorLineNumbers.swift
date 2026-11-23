import AppKit

@MainActor final class EditorLineNumbers: NSRulerView, @MainActor NSTextStorageDelegate {
    private var index = EditorLineIndex()
    private var starts: [Int] { index.starts }
    private var gutterWidth: CGFloat { max(36, CGFloat(String(starts.count).count) * 9 + 16) }
    private var gutterUpdateScheduled = false
    weak var editor: NSTextView?
    init(scroll: NSScrollView, editor: NSTextView) {
        self.editor = editor
        super.init(scrollView: scroll, orientation: .verticalRuler)
        clientView = editor; clipsToBounds = true; wantsLayer = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        index.rebuild(editor.string as NSString)
        ruleThickness = gutterWidth
        editor.textStorage?.delegate = self
    }
    required init(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    @objc func refresh() { needsDisplay = true }
    func rebuild() {
        index.rebuild((editor?.string ?? "") as NSString); updateGutter()
    }
    func textStorage(_ storage: NSTextStorage, didProcessEditing actions: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
        guard actions.contains(.editedCharacters) else { return }
        index.processEdit(in: storage.string as NSString, range: range, delta: delta); updateGutter()
    }
    private func updateGutter() {
        needsDisplay = true
        guard ruleThickness != gutterWidth, !gutterUpdateScheduled else { return }
        gutterUpdateScheduled = true
        // Resizing the ruler can synchronously lay out glyphs. Wait until the
        // current text-storage edit has invalidated the old layout.
        Task { @MainActor [weak self] in
            guard let self else { return }
            gutterUpdateScheduled = false
            let width = gutterWidth
            if ruleThickness != width { ruleThickness = width }
        }
    }
    func cursorPosition(at offset: Int) -> String { index.position(at: offset, in: (editor?.string ?? "") as NSString) }
    private func line(at offset: Int) -> Int { index.line(at: offset) }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        // NSRulerView can call this hook with a dirty rect larger than the
        // gutter. Never fill or draw into neighboring document/header regions.
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor.windowBackgroundColor.setFill(); bounds.intersection(rect).fill()
        guard let editor, let manager = editor.layoutManager, let container = editor.textContainer else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(10, (editor.font?.pointSize ?? 13) - 1), weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let origin = editor.textContainerOrigin
        let visible = editor.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let range = manager.glyphRange(forBoundingRect: visible, in: container)
        manager.enumerateLineFragments(forGlyphRange: range) { [self] box, _, _, glyphs, _ in
            let character = manager.characterIndexForGlyph(at: glyphs.location), index = line(at: character)
            guard starts[index - 1] == character else { return }
            let number = String(index) as NSString
            let y = convert(NSPoint(x: 0, y: box.minY + origin.y), from: editor).y
            number.draw(at: NSPoint(x: ruleThickness - number.size(withAttributes: attributes).width - 8, y: y), withAttributes: attributes)
        }
        if manager.extraLineFragmentTextContainer != nil {
            let number = String(starts.count) as NSString
            let y = convert(NSPoint(x: 0, y: manager.extraLineFragmentRect.minY + origin.y), from: editor).y
            number.draw(at: NSPoint(x: ruleThickness - number.size(withAttributes: attributes).width - 8, y: y), withAttributes: attributes)
        }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}
