import AppKit
import Darwin
import SwiftUI
import TermviaCore

@MainActor final class FileEditorController: NSObject, NSWindowDelegate, NSTextViewDelegate, ObservableObject {
    @MainActor final class Document {
        let key: String, url: URL
        let host: SSHHost?
        var authentication: AuthenticationContext?
        var route: SSHRouteConnection?
        let remotePath: String?
        let findWorkspaceKey: String
        var findOptions = FindOptions()
        let activity: TabActivity
        weak var model: AppModel?
        var data: Data, attempted: Data?
        var observedStamp: CacheStamp?
        var encoding = EditorEncoding.utf8
        var encodingWasSelected = false
        var lineEnding = EditorLineEnding.lf
        var syntax = "auto"
        var customPattern = ""
        var fontSize: CGFloat = 13
        var decodeFailed = false
        weak var ruler: EditorLineNumbers?
        var dirty = false
        var lastError: String?
        var closed = false
        var closing = false
        var refreshBlocksSync = false
        var savingBeforeLeaving = false
        var saveWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
        var refreshing = false
        var refreshTask: Task<Void, Never>?
        var syncing = false
        var textView: NSTextView?
        let undo = UndoManager()
        var view: NSScrollView?
        var highlightTask: Task<Void, Never>?
        var highlightGeneration: UInt64 = 0
        init(key: String, url: URL, data: Data, model: AppModel, host: SSHHost? = nil, remotePath: String? = nil, authentication: AuthenticationContext? = nil, route: SSHRouteConnection? = nil, activity: TabActivity? = nil, findWorkspaceKey: String? = nil) {
            self.key = key; self.url = url; self.data = data; self.model = model; self.host = host; self.remotePath = remotePath; self.authentication = authentication; self.route = route; self.activity = activity ?? TabActivity()
            self.findWorkspaceKey = host.map { "host:" + $0.id.uuidString } ?? findWorkspaceKey ?? "local"
        }
        var title: String { url.lastPathComponent + (host.map { " · " + $0.name } ?? "") }
        var isDisconnected: Bool { remotePath != nil && activity.isClosed }
        func detachConnection() -> SSHRouteConnection? {
            authentication?.replaceCachedSecret(nil)
            authentication = nil
            let detached = route
            route = nil
            return detached
        }
    }
    struct CacheStamp: Equatable { let modified: Date?; let size: UInt64; let inode: UInt64 }
    @Published var revision = 0 { didSet { titlebar?.reload() } }
    private var documents: [Document] = []
    var openDocuments: [Document] { documents.filter { $0.view != nil } }
    var currentDocument: Document? { selectedDocument }
    var isOpening: Bool { !loadingJobs.isEmpty }
    var isVisible: Bool { window?.isVisible == true && !openDocuments.isEmpty }
    func bringToFront() { guard !openDocuments.isEmpty else { return }; window?.collectionBehavior.insert(.moveToActiveSpace); window?.deminiaturize(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate() }
    private var tabMonitor: Any?
    private var pendingClosedSaves: [ObjectIdentifier: Document] = [:]
    private var window: NSWindow?
    private var findPanel: TerminalSearchPanel?
    private let documentHost = NSView()
    private var selectedDocument: Document?
    private var titlebar: EditorTitlebarController?
    private var timer: Timer?
    private var highlighting = false
    private var closeTask: Task<Void, Never>?
    private var shuttingDown = false
    var isClosing: Bool { closeTask != nil }
    let openPrompts = EditorOpenPrompts()
    private struct LoadJob {
        let activityID: UUID?
        let task: Task<Void, Never>
    }
    private var loadingJobs: [String: LoadJob] = [:]
    private var cacheCleanup: [UUID: Task<Void, Never>] = [:]
    private let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Termvia/Editor/" + UUID().uuidString, isDirectory: true)

    func openLocal(_ url: URL, model: AppModel) {
        let key = model.focusedTerminal?.host.map { "host:" + $0.id.uuidString } ?? "local"
        openLocal(url, model: model, findWorkspaceKey: key)
    }
    private func openLocal(_ url: URL, model: AppModel, findWorkspaceKey: String) {
        guard !shuttingDown else { return }
        do {
            let url = try FilePaths.openingTarget(url)
            let key = "local:" + url.standardizedFileURL.path
            if model.settings.useBuiltInEditor, let document = documents.first(where: { $0.key == key }) {
                show(document, data: document.data)
                return
            }
            guard loadingJobs[key] == nil else { return }
            let inspection = try EditorFileInspection.local(url)
            guard !inspection.exceedsEditorLimit else { throw SSHError.invalid("仅支持 16 MB 以内的文件") }
            if inspection.needsSizeConfirmation {
                guard try inspection.isText() else { throw SSHError.invalid("仅支持文本文件") }
                loadingJobs[key] = LoadJob(activityID: nil, task: Task { [weak self] in
                    guard let self else { return }
                    defer { self.loadingJobs[key] = nil }
                    do {
                        guard try await openPrompts.ask(name: url.lastPathComponent, detail: largeFileDetail(inspection), downloadOnly: false, window: model.authenticationPrompts.window ?? NSApp.keyWindow) else { return }
                        try Task.checkCancellation(); openLocalConfirmed(url, model: model, findWorkspaceKey: findWorkspaceKey, sizeConfirmed: true)
                    } catch is CancellationError {} catch { model.error = error.localizedDescription }
                })
            } else { openLocalConfirmed(url, model: model, findWorkspaceKey: findWorkspaceKey) }
        } catch { model.error = error.localizedDescription }
    }
    private func openLocalConfirmed(_ url: URL, model: AppModel, findWorkspaceKey: String, sizeConfirmed: Bool = false) {
        do {
            let data = try readText(url)
            if !sizeConfirmed, data.count > EditorFileInspection.smallFileLimit { openLocal(url, model: model, findWorkspaceKey: findWorkspaceKey); return }
            if !model.settings.useBuiltInEditor { openExternal(url, model: model); return }
            let key = "local:" + url.standardizedFileURL.path
            let document = Document(key: key, url: url, data: data, model: model, findWorkspaceKey: findWorkspaceKey)
            document.encoding = EditorFileInspection(size: UInt64(data.count), header: data).encoding
            documents.append(document); show(document, data: data)
        } catch { model.error = error.localizedDescription }
    }
    private func largeFileDetail(_ inspection: EditorFileInspection) -> String {
        let size = inspection.size.map(FileSizeDisplay.string) ?? T("未知")
        return T("文件大小：%@", size)
    }
    func openRemote(_ entry: RemoteEntry, session: Session, model: AppModel) {
        guard !shuttingDown, !session.activity.isClosed, entry.kind == .file, let original = session.host else { return }
        let activity = session.activity
        let key = "remote:" + activity.id.uuidString + ":" + entry.path
        guard loadingJobs[key] == nil else { return }
        loadingJobs[key] = LoadJob(activityID: activity.id, task: Task { [weak self] in
            guard let self else { return }
            defer { self.loadingJobs[key] = nil }
            do {
                try Task.checkCancellation()
                if let document = documents.first(where: { $0.key == key }) {
                    let data = try readText(document.url)
                    document.attempted = nil; document.observedStamp = nil; document.lastError = nil; synchronize(document)
                    if model.settings.useBuiltInEditor { show(document, data: data) } else { openExternal(document.url, model: model) }
                    return
                }
                let (host, authentication, route) = try await model.editorConnection(for: original)
                var retained = false
                defer { if !retained { route.close() } }
                try Task.checkCancellation()
                let lease = try authentication.lease(); defer { lease.close() }
                route.finishVerification()
                let method = model.fileProtocol(for: session)
                let inspection: EditorFileInspection
                if method == .sftp { inspection = try await lease.inspectFile(entry.path, invocation: model.commands.sftpSubsystem(host)) }
                else {
                    let reply = try await lease.run(model.commands.execute(host, command: EditorFileInspection.sshCommand(path: entry.path)), outputLimit: 65536)
                    guard reply.status == 0 else { throw SSHError.failed(reply.status, reply.output) }
                    inspection = try EditorFileInspection.decodeSSH(reply.output)
                }
                lease.confirmAuthentication(); try Task.checkCancellation()
                let text = try inspection.isText(), downloadOnly = !text || inspection.exceedsEditorLimit
                if downloadOnly || inspection.needsSizeConfirmation {
                    let detail = !text ? T("非文本文件") : inspection.exceedsEditorLimit ? T("仅支持 16 MB 以内的文件") : largeFileDetail(inspection)
                    let destination = downloadOnly ? "\n\n" + model.localPath : ""
                    guard try await openPrompts.ask(name: entry.name, detail: detail + destination, downloadOnly: downloadOnly, window: session.terminal.window ?? NSApp.keyWindow) else { return }
                    try Task.checkCancellation()
                    if downloadOnly {
                        WorkspaceFileActions.download([entry], model: model, session: session, directory: URL(fileURLWithPath: model.localPath, isDirectory: true), confirmed: true)
                        return
                    }
                }
                let folder = sessionCache(activity.id).appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { if !retained { try? FileManager.default.removeItem(at: folder) } }
                let target = URL(fileURLWithPath: try FilePaths.child(entry.name, in: folder.path))
                let success = await withCheckedContinuation { continuation in
                    model.enqueue(local: target.path, remote: entry.path, upload: false, method: method, host: host, authentication: authentication, activity: activity, editorOwned: true) { continuation.resume(returning: $0) }
                }
                guard success else { return }; try Task.checkCancellation()
                let data = try readText(target)
                if !inspection.needsSizeConfirmation, data.count > EditorFileInspection.smallFileLimit {
                    guard try await openPrompts.ask(name: entry.name, detail: largeFileDetail(EditorFileInspection(size: UInt64(data.count), header: data)), downloadOnly: false, window: session.terminal.window ?? NSApp.keyWindow) else { return }
                }
                try Task.checkCancellation()
                let document = Document(key: key, url: target, data: data, model: model, host: host, remotePath: entry.path, authentication: authentication, route: route, activity: activity)
                document.encoding = EditorFileInspection(size: UInt64(data.count), header: data).encoding
                documents.append(document); retained = true; startWatching()
                if model.settings.useBuiltInEditor { show(document, data: data) } else { openExternal(target, model: model) }
            } catch is CancellationError {} catch { if !Task.isCancelled { model.error = error.localizedDescription } }
        })
    }
    private func sessionCache(_ id: UUID) -> URL { cacheRoot.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func readText(_ url: URL) throws -> Data {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw SSHError.invalid("无法打开文件") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw SSHError.invalid("请选择普通文件；目录和符号链接不自动跟随")
        }
        guard metadata.st_size <= EditorFileInspection.editorLimit else { throw SSHError.invalid("仅支持 16 MB 以内的文件") }
        let data = try handle.read(upToCount: Int(EditorFileInspection.editorLimit) + 1) ?? Data()
        guard data.count <= EditorFileInspection.editorLimit else { throw SSHError.invalid("仅支持 16 MB 以内的文件") }
        let inspection = EditorFileInspection(size: UInt64(data.count), header: data)
        guard (inspection.encoding != .utf8 || !data.contains(0)), try inspection.isText() else {
            throw SSHError.invalid("仅支持文本文件")
        }
        return data
    }
    private func openExternal(_ url: URL, model: AppModel) {
        if model.settings.externalEditorPath.isEmpty {
            if !NSWorkspace.shared.open(url) { model.error = T("无法打开文件") }
        } else {
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: model.settings.externalEditorPath), configuration: .init()) { _, error in
                if let error { Task { @MainActor in model.error = error.localizedDescription } }
            }
        }
    }
    private func makeWindow() {
        guard window == nil else { return }
        let controller = NSViewController()
        // Clip ruler drawing to the document, below the native titlebar.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 840, height: 620))
        container.wantsLayer = true; documentHost.wantsLayer = true; documentHost.clipsToBounds = true; controller.view = container
        documentHost.translatesAutoresizingMaskIntoConstraints = false; documentHost.identifier = .init("Termvia.Editor.Content")
        let footer = NSHostingView(rootView: EditorFooter(controller: self)); footer.sizingOptions = []; footer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(documentHost); container.addSubview(footer)
        NSLayoutConstraint.activate([
            documentHost.leadingAnchor.constraint(equalTo: container.leadingAnchor), documentHost.trailingAnchor.constraint(equalTo: container.trailingAnchor), documentHost.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor), documentHost.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor), footer.trailingAnchor.constraint(equalTo: container.trailingAnchor), footer.bottomAnchor.constraint(equalTo: container.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 24)
        ])
        let window = NSWindow(contentViewController: SidebarSurfaceController(content: controller))
        window.setContentSize(NSSize(width: 840, height: 620)); window.minSize = NSSize(width: 480, height: 260)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]; window.isReleasedWhenClosed = false
        window.identifier = .init("Termvia.FileEditor"); window.isExcludedFromWindowsMenu = true; window.tabbingMode = .disallowed
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]; window.delegate = self
        window.title = ""; window.center(); self.window = window
        titlebar = EditorTitlebarController(controller: self, window: window)
        tabMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self, weak window] event in
            guard let self, let window, window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
            if (event.window === window || event.window === self.findPanel), AppShortcutBinding("f").matches(event) {
                if !event.isARepeat { self.showFind() }
                return nil
            }
            guard event.window === window else { return event }
            if event.type == .keyDown, event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" { self.closeCurrent(); return nil }
            return event
        }
    }
    private func show(_ document: Document, data current: Data) {
        guard !shuttingDown else { return }
        // Reopening a tab must retain its unsaved buffer and format choices.
        if document.view != nil { select(document); bringToFront(); return }
        let decoded = document.encoding.decode(current)
        document.decodeFailed = decoded == nil
        let text = EditorLineEnding.lf.apply(decoded ?? String(decoding: current, as: UTF8.self))
        if decoded?.contains("\r\n") == true { document.lineEnding = .crlf }
        makeWindow()
        if document.view == nil {
            document.findOptions = document.model?.findOptions(for: document.findWorkspaceKey) ?? FindOptions()
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 550))
            scroll.clipsToBounds = true
            scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.autohidesScrollers = true
            scroll.backgroundColor = .textBackgroundColor
            let editor = NSTextView(usingTextLayoutManager: false)
            editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
            editor.autoresizingMask = [.width]; editor.minSize = .zero
            editor.frame = NSRect(origin: .zero, size: scroll.contentSize)
            editor.textContainer?.widthTracksTextView = true
            editor.textContainer?.heightTracksTextView = false
            editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
            editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false; editor.isContinuousSpellCheckingEnabled = false
            editor.font = .monospacedSystemFont(ofSize: document.fontSize, weight: .regular)
            editor.textColor = .textColor; editor.backgroundColor = .textBackgroundColor; editor.textContainerInset = NSSize(width: 10, height: 10)
            editor.string = text; editor.isEditable = !document.decodeFailed; editor.delegate = self; scroll.documentView = editor
            let ruler = EditorLineNumbers(scroll: scroll, editor: editor); document.ruler = ruler
            scroll.verticalRulerView = ruler; scroll.hasVerticalRuler = true; scroll.hasHorizontalRuler = false; scroll.rulersVisible = true; scroll.tile()
            editor.sizeToFit()
            document.textView = editor; document.view = scroll; highlight(document)
        }
        select(document)
        window?.title = document.title
        window?.collectionBehavior.insert(.moveToActiveSpace)
        window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(document.textView)
        NSApp.activate(ignoringOtherApps: true); revision += 1
    }
    func textDidChange(_ notification: Notification) {
        guard !highlighting, let text = notification.object as? NSTextView, let document = documents.first(where: { $0.textView === text }), !document.refreshing, !document.isDisconnected else { return }
        document.refreshBlocksSync = false
        document.dirty = true
        text.sizeToFit(); revision += 1
        highlight(document, delayed: true)
        if document === currentDocument { findPanel?.editorTextChanged() }
    }
    func undoManager(for view: NSTextView) -> UndoManager? {
        documents.first(where: { $0.textView === view })?.undo
    }
    @discardableResult private func save(_ document: Document) -> Bool {
        guard !shuttingDown, !document.closed, !document.isDisconnected else { return false }
        guard (!document.refreshing || document.savingBeforeLeaving), !document.refreshBlocksSync else { return true }
        do {
            if let editor = document.textView, document.dirty {
                guard !document.decodeFailed, let data = document.encoding.encode(document.lineEnding.apply(editor.string)) else { throw SSHError.invalid("当前编码无法无损保存此文本") }
                guard data.count <= 16 * 1024 * 1024 else { throw SSHError.invalid("仅支持 16 MB 以内的文件") }
                if (try? Data(contentsOf: document.url)) != data {
                    let permissions = try FileManager.default.attributesOfItem(atPath: document.url.path)[.posixPermissions]
                    try data.write(to: document.url, options: .atomic)
                    if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: document.url.path) }
                }
                document.dirty = false
                if document.remotePath == nil { document.data = data }
            }
            if document.remotePath != nil { synchronize(document) }
            return true
        } catch { document.model?.error = error.localizedDescription; return false }
    }
    private func startWatching() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.scan() } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func scan() {
        for document in documents where document.remotePath != nil { synchronize(document) }
    }
    private func synchronize(_ document: Document) {
        guard !shuttingDown, !document.isDisconnected, !document.refreshBlocksSync, (!document.refreshing || document.savingBeforeLeaving), !document.syncing, let model = document.model, let host = document.host, let remote = document.remotePath else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: document.url.path)
            let stamp = CacheStamp(modified: attributes[.modificationDate] as? Date, size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0, inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
            guard stamp != document.observedStamp else {
                if !document.syncing { finishSaveWaiters(document, success: document.attempted == nil); if document.closed { document.route?.close() } }
                return
            }
            let data = try readText(document.url)
            document.observedStamp = stamp
            if !document.refreshing, !document.dirty, let editor = document.textView, document.encoding.encode(document.lineEnding.apply(editor.string)) != data, let text = document.encoding.decode(data) {
                editor.string = EditorLineEnding.lf.apply(text); document.undo.removeAllActions(); document.ruler?.rebuild(); editor.sizeToFit(); highlight(document)
                if document === currentDocument { findPanel?.editorTextChanged() }
            }
            document.lastError = nil
            guard data != document.data, data != document.attempted else {
                // Reentrant cache observations must wait for the upload's result.
                if !document.syncing { finishSaveWaiters(document, success: data == document.data); if document.closed { document.route?.close() } }
                return
            }
            document.attempted = data; document.syncing = true
            // Editors often replace cache files atomically. Upload a stable snapshot;
            // further edits are sent by the next scan after this upload completes.
            let folder = document.url.deletingLastPathComponent().appendingPathComponent(".sync-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let snapshot = folder.appendingPathComponent(document.url.lastPathComponent)
            try data.write(to: snapshot); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
            revision += 1
            model.enqueue(local: snapshot.path, remote: remote, upload: true, method: host.fileProtocol ?? .sftp, host: host, authentication: document.authentication, activity: document.activity, editorOwned: true) { [weak self, document] success in
                try? FileManager.default.removeItem(at: folder)
                document.syncing = false
                if document.isDisconnected {
                    self?.pendingClosedSaves.removeValue(forKey: ObjectIdentifier(document))
                    return
                }
                if success { document.data = data; document.attempted = nil }
                self?.revision += 1
                if success { self?.synchronize(document) }
                else { self?.finishSaveWaiters(document, success: false); if document.closed { document.route?.close() } }
                if document.closed, !document.syncing {
                    self?.pendingClosedSaves.removeValue(forKey: ObjectIdentifier(document))
                }
            }
        } catch {
            document.syncing = false; finishSaveWaiters(document, success: false)
            if document.lastError != error.localizedDescription { document.lastError = error.localizedDescription; document.model?.error = error.localizedDescription }
        }
    }
    private func finishSaveWaiters(_ document: Document, success: Bool) {
        let waiting = Array(document.saveWaiters.values); document.saveWaiters.removeAll()
        for continuation in waiting { continuation.resume(returning: success) }
    }
    private func saveAndWait(_ document: Document) async throws -> Bool {
        try Task.checkCancellation()
        let id = UUID()
        document.savingBeforeLeaving = true; document.refreshBlocksSync = false
        defer { document.savingBeforeLeaving = false }
        let success = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                document.saveWaiters[id] = continuation
                if !document.syncing { document.attempted = nil }
                document.observedStamp = nil
                if !save(document) { finishSaveWaiters(document, success: false) }
                else if document.remotePath == nil { finishSaveWaiters(document, success: true) }
            }
        }, onCancel: { Task { @MainActor in document.saveWaiters.removeValue(forKey: id)?.resume(returning: false) } })
        try Task.checkCancellation(); return success
    }
    @objc func refreshCurrent() {
        guard let document = currentDocument, let model = document.model, !document.refreshing, !document.closing, !document.isDisconnected, !shuttingDown else { return }
        document.highlightTask?.cancel(); document.highlightTask = nil
        document.refreshing = true; document.textView?.isEditable = false; revision += 1
        document.refreshTask = Task { [weak self, weak document] in
            guard let self, let document else { return }
            defer {
                document.refreshTask = nil; document.refreshing = false
                if !document.closed {
                    document.textView?.isEditable = !document.decodeFailed && !document.closing && !document.isDisconnected
                    if document.dirty { highlight(document) }
                }
                revision += 1
            }
            do {
                let pendingRemote = document.remotePath != nil && (document.syncing || document.attempted != nil || (try? readText(document.url)) != document.data)
                if document.dirty || pendingRemote {
                    switch try await openPrompts.confirmRefresh(name: document.title, window: window) {
                    case .save:
                        guard try await saveAndWait(document) else { return }
                    case .discard:
                        // Failed reloads must not autosave discarded edits over the file.
                        if document.dirty { document.refreshBlocksSync = true }
                    case .cancel, .proceed: return
                    }
                }
                try Task.checkCancellation()
                // Reload this document's existing local file or remote cache only.
                let data = try readText(document.url)
                if data.count > EditorFileInspection.smallFileLimit, document.data.count <= EditorFileInspection.smallFileLimit {
                    guard try await openPrompts.ask(name: document.title, detail: largeFileDetail(EditorFileInspection(size: UInt64(data.count), header: data)), downloadOnly: false, window: window) else { return }
                }
                try Task.checkCancellation()
                guard !document.closed, let editor = document.textView else { return }
                let bom = EditorFileInspection(size: UInt64(data.count), header: data).encoding
                if bom != .utf8 || !document.encodingWasSelected { document.encoding = bom }
                let decoded = document.encoding.decode(data)
                document.decodeFailed = decoded == nil
                editor.isEditable = decoded != nil
                document.lineEnding = decoded?.contains("\r\n") == true ? .crlf : .lf
                let cursor = editor.selectedRange().location
                editor.string = EditorLineEnding.lf.apply(decoded ?? String(decoding: data, as: UTF8.self))
                editor.undoManager?.removeAllActions()
                editor.setSelectedRange(NSRange(location: min(cursor, (editor.string as NSString).length), length: 0))
                // Remote data/attempts/stamps belong to the cache uploader. A
                // display reload must not mark pending cache edits as uploaded.
                if document.remotePath == nil { document.data = data }
                document.dirty = false; document.refreshBlocksSync = false
                document.ruler?.rebuild(); editor.sizeToFit(); highlight(document)
                if document === currentDocument { findPanel?.editorTextChanged() }
            } catch is CancellationError {} catch { if !document.closed { model.error = error.localizedDescription } }
        }
    }
    private func cancelRefresh(_ document: Document) {
        document.refreshTask?.cancel(); document.refreshTask = nil
        document.refreshing = false
    }
    @objc func saveCurrent() {
        guard let document = currentDocument, !document.refreshing, !document.closing, !document.isDisconnected, !shuttingDown else { return }
        document.refreshBlocksSync = false; document.attempted = nil; document.observedStamp = nil; save(document); revision += 1
    }
    func showFind() {
        guard let document = currentDocument, let editor = document.textView, let window,
              window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        let panel = findPanel ?? TerminalSearchPanel()
        findPanel = panel
        panel.present(for: editor, in: window, options: document.findOptions) { [weak document] options in
            document?.findOptions = options
        }
    }
    func localizeFind() { findPanel?.localize() }
    func select(_ document: Document) {
        guard let view = document.view else { return }
        if selectedDocument !== document {
            findPanel?.close()
            for old in documentHost.subviews { old.removeFromSuperview() }
            selectedDocument = document
            view.frame = documentHost.bounds; view.autoresizingMask = [.width, .height]
            documentHost.addSubview(view)
        }
        window?.contentView?.layoutSubtreeIfNeeded(); view.tile()
        window?.title = document.title
        window?.makeFirstResponder(document.textView); document.textView?.needsDisplay = true
        revision += 1
    }
    func reorderDocuments(_ keys: [String], before target: String?) {
        let visible = Set(openDocuments.map(\.key))
        guard Set(keys).isSubset(of: visible), target.map({ visible.contains($0) }) ?? true,
              let reordered = TabOrdering.moving(documents, ids: keys, before: target, id: \.key),
              reordered.map(\.key) != documents.map(\.key) else { return }
        documents = reordered
        revision += 1
    }
    @objc func closeCurrent() { if let document = currentDocument { close(document) } }
    func close(_ document: Document) { requestClose([document]) }
    func closeOthers(_ document: Document) { requestClose(openDocuments.filter { $0 !== document }) }
    func closeAll() { requestClose(openDocuments) }

    private func hasUnsavedChanges(_ document: Document) -> Bool {
        guard !document.isDisconnected else { return false }
        if document.dirty { return true }
        guard document.remotePath != nil else { return false }
        // A saved cache is still unsaved at its destination until upload succeeds.
        return document.syncing || document.attempted != nil || (try? readText(document.url)) != document.data
    }

    private func requestClose(_ requested: [Document], wholeWindow: Bool = false) {
        guard !shuttingDown, closeTask == nil else { return }
        let requested = requested.filter { !$0.closed && $0.view != nil }
        let confirmAll = wholeWindow && requested.count > 1
        // Clean tabs need no asynchronous work or save operation.
        if !confirmAll, requested.allSatisfy({ !hasUnsavedChanges($0) && !$0.refreshing }) {
            if wholeWindow { cancelOpenJobs() }
            for document in requested { removeDocument(document) }
            if wholeWindow, openDocuments.isEmpty { window?.orderOut(nil) }
            return
        }
        closeTask = Task { [weak self] in
            guard let self else { return }
            defer { closeTask = nil }
            do {
                if confirmAll {
                    guard try await openPrompts.confirmCloseAll(window: window) else { return }
                }
                try Task.checkCancellation()
                guard !shuttingDown else { return }
                if wholeWindow { cancelOpenJobs() }
                let closing = wholeWindow ? openDocuments : requested
                for document in closing where !document.closed {
                    guard try await closeOne(document) else { return }
                }
            } catch is CancellationError {} catch { requested.first?.model?.error = error.localizedDescription }
        }
    }
    private func closeOne(_ document: Document) async throws -> Bool {
        try Task.checkCancellation()
        guard !shuttingDown, !document.closed else { return false }
        cancelRefresh(document)
        document.closing = true; document.textView?.isEditable = false
        defer {
            document.closing = false
            if !document.closed { document.textView?.isEditable = !document.decodeFailed && !document.isDisconnected }
            revision += 1
        }
        if hasUnsavedChanges(document) {
            select(document)
            switch try await openPrompts.confirmClose(name: document.title, window: window) {
            case .save:
                guard try await saveAndWait(document) else { return false }
            case .discard: break
            case .cancel, .proceed: return false
            }
        }
        try Task.checkCancellation()
        guard !shuttingDown, !document.closed else { return false }
        removeDocument(document); return true
    }
    private func cancelOpenJobs() {
        for job in loadingJobs.values { job.task.cancel() }
    }
    private func removeDocument(_ document: Document, selectNext: Bool = true) {
        guard !document.closed else { return }
        cancelRefresh(document)
        document.highlightTask?.cancel(); document.closed = true
        finishSaveWaiters(document, success: false)
        if document.syncing, !document.isDisconnected { pendingClosedSaves[ObjectIdentifier(document)] = document }
        let index = openDocuments.firstIndex { $0 === document } ?? 0
        document.view?.removeFromSuperview(); document.view = nil; document.textView = nil
        document.undo.removeAllActions()
        documents.removeAll { $0 === document }
        if selectedDocument === document {
            findPanel?.close()
            selectedDocument = nil
            let remaining = openDocuments
            if selectNext, !remaining.isEmpty { select(remaining[min(index, remaining.count - 1)]) }
        }
        // Already approved uploads retain their stable snapshots/authentication.
        if !document.syncing { document.route?.close() }
        if openDocuments.isEmpty { window?.orderOut(nil) }
        revision += 1
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestClose(openDocuments, wholeWindow: true)
        return false
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView, currentDocument?.textView === editor else { return }
        findPanel?.editorSelectionChanged()
        objectWillChange.send()
    }
    var cursorPosition: String {
        guard let editor = currentDocument?.textView else { return "1:1" }
        return currentDocument?.ruler?.cursorPosition(at: editor.selectedRange().location) ?? "1:1"
    }
    func zoom(_ delta: CGFloat) {
        guard let document = currentDocument else { return }
        document.fontSize = min(36, max(9, document.fontSize + delta)); document.textView?.font = .monospacedSystemFont(ofSize: document.fontSize, weight: .regular)
        document.textView?.sizeToFit(); document.ruler?.rebuild(); revision += 1
    }
    func setEncoding(_ encoding: EditorEncoding) {
        guard let document = currentDocument, let editor = document.textView, !document.closing, !document.isDisconnected else { return }
        if document.dirty {
            guard encoding.encode(document.lineEnding.apply(editor.string)) != nil else { document.model?.error = T("当前编码无法无损保存此文本"); return }
            document.encoding = encoding; document.decodeFailed = false; document.refreshBlocksSync = false; highlight(document)
        } else {
            guard let data = try? readText(document.url), let text = encoding.decode(data) else { document.model?.error = T("无法使用所选编码打开文件"); return }
            document.encoding = encoding; document.decodeFailed = false; editor.isEditable = true
            document.lineEnding = text.contains("\r\n") ? .crlf : .lf
            editor.string = EditorLineEnding.lf.apply(text); document.undo.removeAllActions(); document.ruler?.rebuild(); editor.sizeToFit(); highlight(document)
            findPanel?.editorTextChanged()
        }
        document.encodingWasSelected = true
        revision += 1
    }
    func setLineEnding(_ ending: EditorLineEnding) { guard let document = currentDocument, !document.decodeFailed, !document.closing, !document.isDisconnected else { return }; document.lineEnding = ending; document.refreshBlocksSync = false; document.dirty = true; revision += 1 }
    func setSyntax(_ syntax: String) {
        guard let document = currentDocument else { return }
        if syntax == "custom" {
            let alert = CompactAlert(); alert.messageText = T("自定义高亮规则")
            let field = NSTextField(string: document.customPattern); field.frame = NSRect(x: 0, y: 0, width: 260, height: 24); alert.accessoryView = field
            alert.addButton(withTitle: T("保存")); alert.addButton(withTitle: T("取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do { _ = try NSRegularExpression(pattern: field.stringValue); document.customPattern = field.stringValue }
            catch { document.model?.error = error.localizedDescription; return }
        }
        document.syntax = syntax; highlight(document); revision += 1
    }
    private func highlight(_ document: Document, delayed: Bool = false) {
        document.highlightTask?.cancel(); document.highlightGeneration &+= 1
        guard document.textView != nil, !document.closed else { return }
        let generation = document.highlightGeneration, pattern = document.customPattern
        let language = document.syntax == "auto" ? (document.url.lastPathComponent.lowercased() == "dockerfile" ? "dockerfile" : document.url.pathExtension.lowercased()) : document.syntax
        document.highlightTask = Task { [weak self, weak document] in
            defer {
                if let document, document.highlightGeneration == generation { document.highlightTask = nil }
            }
            if delayed { do { try await Task.sleep(for: .milliseconds(650)) } catch { return } }
            guard !Task.isCancelled else { return }
            // Snapshot after debouncing so rapid typing does not copy a large
            // buffer on every keystroke. Do not retain its document while matching.
            let snapshot: String? = {
                guard let document, !document.closed, !document.refreshing,
                      document.highlightGeneration == generation else { return nil }
                return document.textView?.string
            }()
            guard let text = snapshot else { return }
            let worker = Task.detached(priority: .utility) { EditorSyntaxHighlighter.matches(in: text, language: language, pattern: pattern) }
            let spans = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, let self, let document, !document.closed, !document.refreshing,
                  document.highlightGeneration == generation, let editor = document.textView,
                  editor.string == text, let storage = editor.textStorage else { return }
            self.highlighting = true
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: NSRange(location: 0, length: storage.length))
            for span in spans {
                let color: NSColor
                switch span.style { case .keyword: color = .systemPurple; case .number: color = .systemOrange; case .string: color = .systemRed; case .comment: color = .secondaryLabelColor }
                storage.addAttribute(.foregroundColor, value: color, range: span.range)
            }
            storage.endEditing()
            editor.typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: document.fontSize, weight: .regular), .foregroundColor: NSColor.textColor]
            self.highlighting = false
        }
    }
    func disconnectRemoteDocuments(for activity: TabActivity, transfers: [Task<Void, Never>]) {
        let id = activity.id
        let loads = loadingJobs.values.filter { $0.activityID == id }.map(\.task)
        for load in loads { load.cancel() }
        let owned = documents.filter { $0.remotePath != nil && $0.activity === activity }
        var routes = (owned + pendingClosedSaves.values.filter { $0.activity === activity }).compactMap { $0.detachConnection() }
        if transfers.isEmpty {
            for route in routes { route.close() }
            routes.removeAll()
        }
        for document in owned {
            if document.closing { closeTask?.cancel() }
            cancelRefresh(document)
            finishSaveWaiters(document, success: false)
            if document.view == nil { removeDocument(document) }
            else {
                document.textView?.isEditable = false
                document.undo.removeAllActions()
            }
        }
        if let currentDocument, currentDocument.isDisconnected { findPanel?.editorTextChanged() }
        if !owned.isEmpty { revision += 1 }
        if !documents.contains(where: { $0.remotePath != nil && !$0.isDisconnected }) {
            timer?.invalidate(); timer = nil
        }
        let directory = sessionCache(id)
        guard !loads.isEmpty || !transfers.isEmpty || FileManager.default.fileExists(atPath: directory.path) else { return }
        cacheCleanup[id] = Task {
            // Keep editor jump/proxy routes only long enough for cancelled uploads to discard staging.
            for task in transfers { await task.value }
            for route in routes { route.close() }
            for load in loads { await load.value }
            try? FileManager.default.removeItem(at: directory)
            cacheCleanup[id] = nil
        }
    }
    deinit { if let tabMonitor { NSEvent.removeMonitor(tabMonitor) } }
    func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        closeTask?.cancel(); closeTask = nil
        timer?.invalidate(); timer = nil
        openPrompts.cancelAll(); cancelOpenJobs()
        // Quit overrides every sheet/close sequence. Never save or enqueue new
        // uploads here; the application cancels transfers during shutdown.
        for document in documents {
            removeDocument(document, selectNext: false)
        }
        window?.orderOut(nil)
    }
    func finishShutdown() async {
        for job in Array(loadingJobs.values) { await job.task.value }
        for task in Array(cacheCleanup.values) { await task.value }
        try? FileManager.default.removeItem(at: cacheRoot)
    }
}

private struct EditorFooter: View {
    @ObservedObject var controller: FileEditorController
    private let formats = ["auto", "plain", "swift", "c", "cpp", "go", "rs", "js", "ts", "py", "sh", "json", "yaml", "toml", "html", "css", "sql", "md", "custom"]
    var body: some View {
        HStack(spacing: 8) {
            Text(T("行/列") + " " + controller.cursorPosition).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let document = controller.currentDocument {
                if document.isDisconnected {
                    Text(T("已断开")).font(.caption).foregroundStyle(.secondary)
                }
                NativePopUpPicker(selection: Binding(get: { document.encoding }, set: { controller.setEncoding($0) }), options: EditorEncoding.allCases.map { ($0, $0.rawValue) }, label: "编码", identifier: "Termvia.Editor.Encoding", preferredEdge: .top).frame(width: 112)
                    .disabled(document.isDisconnected)
                NativePopUpPicker(selection: Binding(get: { document.lineEnding }, set: { controller.setLineEnding($0) }), options: EditorLineEnding.allCases.map { ($0, $0.rawValue) }, label: "换行符", identifier: "Termvia.Editor.LineEnding", preferredEdge: .top).frame(width: 72)
                    .disabled(document.isDisconnected)
                NativePopUpPicker(selection: Binding(get: { document.syntax }, set: { controller.setSyntax($0) }), options: formats.map { ($0, $0 == "auto" ? T("自动识别") : $0 == "plain" ? T("纯文本") : $0 == "custom" ? T("自定义…") : $0.uppercased()) }, label: "语法高亮", identifier: "Termvia.Editor.Syntax", preferredEdge: .top).frame(width: 120)
            }
        }.padding(.horizontal, 8).controlSize(.mini).disabled(controller.currentDocument?.refreshing == true || controller.currentDocument?.closing == true).background(.bar)
    }
}
