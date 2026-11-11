import AppKit
import TermviaCore

enum FileConflictChoice { case replace, skip, cancel, saveAs(URL) }
struct TransferSkipped: Error {}

/// Conflict decisions are independent of the optional transfer confirmation.
/// Queue native sheets so concurrent jobs never cover one another's questions.
@MainActor final class FileConflictPrompts {
    weak var window: NSWindow?
    private struct Request {
        let id = UUID()
        let scope: UUID
        let path: String
        let directory: Bool
        let rename: URL?
        let continuation: CheckedContinuation<FileConflictChoice, Never>
    }
    private var pending: [Request] = []
    private var current: Request?
    private(set) var alert: NSAlert?
    private var panel: NSSavePanel?
    private var observer: NSObjectProtocol?
    private weak var observedWindow: NSWindow?
    private var stopped = false
    func ask(path: String, directory: Bool, scope: UUID, rename: URL? = nil) async throws -> FileConflictChoice {
        try Task.checkCancellation()
        let answer = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<FileConflictChoice, Never>) in
                guard !stopped else { continuation.resume(returning: .cancel); return }
                pending.append(Request(scope: scope, path: path, directory: directory, rename: rename, continuation: continuation))
                presentNext()
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel(scope: scope) } })
        try Task.checkCancellation()
        if case .cancel = answer { throw CancellationError() }
        return answer
    }
    private func presentNext() {
        guard !stopped, current == nil, !pending.isEmpty else { return }
        guard let window else { let waiting = pending; pending = []; for request in waiting { request.continuation.resume(returning: .cancel) }; return }
        if observedWindow !== window {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observedWindow = window
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.presentNext() }
            }
        }
        guard window.attachedSheet == nil else { return }
        let request = pending.removeFirst(); current = request
        let alert = NSAlert(); self.alert = alert
        alert.messageText = T(request.directory ? "文件夹已存在：%@" : "文件已存在：%@", (request.path as NSString).lastPathComponent)
        alert.informativeText = request.path + (request.directory ? "\n\n" + T("合并会保留目标独有内容；同名文件仍逐项询问是否覆盖。") : "\n\n" + T("是否覆盖目标中的同名文件？"))
        let accept = alert.addButton(withTitle: T(request.directory ? "合并" : "覆盖"))
        accept.hasDestructiveAction = !request.directory
        if !request.directory { accept.keyEquivalent = "" }
        alert.addButton(withTitle: T("跳过"))
        alert.addButton(withTitle: T("取消")).keyEquivalent = "\u{1b}"
        if request.rename != nil { alert.addButton(withTitle: T("另存为…")) }
        alert.window.identifier = NSUserInterfaceItemIdentifier("Termvia.FileConflict")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.current?.id == request.id else { return }
            self.alert = nil
            if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3, let target = request.rename {
                let panel = NSSavePanel(); self.panel = panel
                panel.directoryURL = target.deletingLastPathComponent(); panel.nameFieldStringValue = target.lastPathComponent
                panel.beginSheetModal(for: window) { [weak self] result in
                    guard let self, self.current?.id == request.id else { return }
                    self.panel = nil
                    self.finish(result == .OK && panel.url != nil ? .saveAs(panel.url!) : .skip)
                }
            } else {
                self.finish(response == .alertFirstButtonReturn ? .replace : response == .alertSecondButtonReturn ? .skip : .cancel)
            }
        }
    }
    private func finish(_ choice: FileConflictChoice) {
        let request = current; current = nil; alert = nil; panel = nil
        request?.continuation.resume(returning: choice)
        presentNext()
    }
    func cancel(scope: UUID) {
        let removed = pending.filter { $0.scope == scope }; pending.removeAll { $0.scope == scope }
        for request in removed { request.continuation.resume(returning: .cancel) }
        if current?.scope == scope {
            let request = current; current = nil
            if let alert { alert.window.sheetParent?.endSheet(alert.window, returnCode: .cancel) }
            panel?.cancel(nil); alert = nil; panel = nil
            request?.continuation.resume(returning: .cancel)
        }
    }
    func cancelAll() {
        stopped = true
        let scopes = pending.map(\.scope) + [current?.scope].compactMap { $0 }
        for scope in scopes { cancel(scope: scope) }
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
    }
}
