import AppKit
import TermviaCore

/// Serialize native editor sheets independently of transfer confirmations.
enum EditorOpenChoice { case proceed, save, discard, cancel }

@MainActor final class EditorOpenPrompts {
    private enum Kind { case open, download, refresh, close, closeAll }
    private struct Request {
        let id: UUID, name: String, detail: String, kind: Kind, window: NSWindow
        let continuation: CheckedContinuation<EditorOpenChoice, Never>
    }
    private var pending: [Request] = []
    private var current: Request?
    private(set) var alert: CompactAlert?
    private var observers: [NSObjectProtocol] = []
    init() {
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: nil, queue: .main) { [weak self] _ in DispatchQueue.main.async { self?.presentNext() } })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { if let window = note.object as? NSWindow { self?.cancel(window: window) } }
        })
    }
    func ask(name: String, detail: String, downloadOnly: Bool, window: NSWindow?) async throws -> Bool {
        try await ask(name: name, detail: detail, kind: downloadOnly ? .download : .open, window: window) == .proceed
    }
    func confirmRefresh(name: String, window: NSWindow?) async throws -> EditorOpenChoice {
        try await ask(name: name, detail: "", kind: .refresh, window: window)
    }
    func confirmClose(name: String, window: NSWindow?) async throws -> EditorOpenChoice {
        try await ask(name: name, detail: "", kind: .close, window: window)
    }
    func confirmCloseAll(window: NSWindow?) async throws -> Bool {
        try await ask(name: "", detail: "", kind: .closeAll, window: window) == .proceed
    }
    private func ask(name: String, detail: String, kind: Kind, window: NSWindow?) async throws -> EditorOpenChoice {
        try Task.checkCancellation()
        guard let window, window.isVisible else { throw CancellationError() }
        let id = UUID()
        let answer = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                pending.append(Request(id: id, name: name, detail: detail, kind: kind, window: window, continuation: continuation)); presentNext()
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel(id: id) } })
        try Task.checkCancellation(); return answer
    }
    private func presentNext() {
        guard current == nil, let request = pending.first else { return }
        guard request.window.isVisible else { cancel(id: request.id); return }
        guard request.window.attachedSheet == nil else { return }
        pending.removeFirst(); current = request
        let alert = CompactAlert(); self.alert = alert
        switch request.kind {
        case .open: alert.messageText = T("打开大文件？")
        case .download: alert.messageText = T("无法编辑此文件")
        case .refresh: alert.messageText = T("刷新前是否保存文件？")
        case .close: alert.messageText = T("关闭前是否保存文件？")
        case .closeAll: alert.messageText = T("是否全部关闭？")
        }
        alert.informativeText = [request.name, request.detail].filter { !$0.isEmpty }.joined(separator: "\n\n")
        if request.kind == .refresh || request.kind == .close {
            alert.addButton(withTitle: T("保存"))
            alert.addButton(withTitle: T("不保存"))
        } else if request.kind == .closeAll {
            alert.addButton(withTitle: T("全部关闭"))
        } else {
            let proceed = alert.addButton(withTitle: T(request.kind == .download ? "下载" : "继续打开")); proceed.keyEquivalent = ""
        }
        if request.kind != .refresh && request.kind != .close {
            alert.addButton(withTitle: T("取消")).keyEquivalent = "\u{1b}"
        }
        alert.window.identifier = .init(request.kind == .close ? "Termvia.Editor.CloseConfirmation" : request.kind == .closeAll ? "Termvia.Editor.CloseAllConfirmation" : "Termvia.Editor.OpenConfirmation")
        alert.beginSheetModal(for: request.window) { [weak self] response in
            guard let self, self.current?.id == request.id else { return }
            self.current = nil; self.alert = nil
            let choice: EditorOpenChoice
            if request.kind == .refresh || request.kind == .close { choice = response == .alertFirstButtonReturn ? .save : response == .alertSecondButtonReturn ? .discard : .cancel }
            else { choice = response == .alertFirstButtonReturn ? .proceed : .cancel }
            request.continuation.resume(returning: choice); self.presentNext()
        }
    }
    private func cancel(id: UUID) {
        if let index = pending.firstIndex(where: { $0.id == id }) { pending.remove(at: index).continuation.resume(returning: .cancel) }
        if current?.id == id {
            let request = current; current = nil
            if let alert { alert.window.sheetParent?.endSheet(alert.window, returnCode: .cancel) }
            alert = nil; request?.continuation.resume(returning: .cancel)
        }
        presentNext()
    }
    private func cancel(window: NSWindow) {
        let ids = pending.filter { $0.window === window }.map(\.id) + (current?.window === window ? [current!.id] : [])
        for id in ids { cancel(id: id) }
    }
    func cancelAll() { let ids = pending.map(\.id) + [current?.id].compactMap { $0 }; for id in ids { cancel(id: id) } }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}
