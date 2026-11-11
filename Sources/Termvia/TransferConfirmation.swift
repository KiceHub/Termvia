import AppKit
import TermviaCore

extension AppModel {
    func confirmTransfer(sources: [String], destination: String, upload: Bool, perform: @escaping @MainActor () -> Void) {
        guard !sources.isEmpty else { return }
        guard settings.confirmTransfers else { perform(); return }
        guard transferConfirmation == nil, let window = authenticationPrompts.window, window.attachedSheet == nil else {
            error = T("请先关闭当前对话框后再传输"); return
        }
        let alert = NSAlert()
        alert.messageText = T(upload ? "确认上传？" : "确认下载？")
        alert.informativeText = ""
        let source = NSTextField(wrappingLabelWithString: sources.joined(separator: "\n"))
        let target = NSTextField(wrappingLabelWithString: destination)
        for field in [source, target] {
            field.isSelectable = true; field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.preferredMaxLayoutWidth = 340; field.lineBreakMode = .byCharWrapping
            field.widthAnchor.constraint(equalToConstant: 340).isActive = true
        }
        let stack = NSStackView(views: [NSTextField(labelWithString: T("来源")), source, NSTextField(labelWithString: T("目标")), target])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.widthAnchor.constraint(equalToConstant: 340).isActive = true
        let height = max(100, stack.fittingSize.height)
        let document = TransferPathDocument(frame: NSRect(x: 0, y: 0, width: 340, height: height))
        stack.frame = document.bounds; document.addSubview(stack)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: min(220, height)))
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.documentView = document; alert.accessoryView = scroll
        alert.addButton(withTitle: T("开始传输")); alert.addButton(withTitle: T("取消"))
        alert.showsSuppressionButton = true; alert.suppressionButton?.title = T("不再提示")
        transferConfirmation = alert
        transferConfirmationOwner = active?.activity
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.transferConfirmation = nil
            self.transferConfirmationOwner = nil
            guard response == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on { self.settings.confirmTransfers = false; self.saveSettings() }
            perform()
        }
    }
}

private final class TransferPathDocument: NSView {
    override var isFlipped: Bool { true }
}
