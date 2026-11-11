import AppKit
import SwiftUI
import SwiftTerm
import TermviaCore

enum SessionPhase: Equatable {
    case ready, connecting, running, stopping, exited(Int32?), failed(String)
    var isActive: Bool { self == .ready || self == .connecting || self == .running || self == .stopping }
    var label: String {
        switch self {
        case .ready: return T("准备启动")
        case .connecting: return T("正在连接")
        case .running: return T("进程运行中")
        case .stopping: return T("正在停止")
        case .exited(let code): return code.map {  $0 == 0 ? T("已结束") : T("已退出（%d）", $0) } ?? T("已终止")
        case .failed: return T("启动失败")
        }
    }
}

@MainActor final class Session: ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    private(set) var host: SSHHost?
    let isStartPage: Bool
    lazy var terminal = ThemedTerminalView(frame: .zero)
    private(set) var invocation: Invocation
    private(set) var authentication: AuthenticationContext?
    let activity: TabActivity
    var connectionSecurity: SSHConnectionSecurity?
    let monitor = RemoteMonitor()
    var sidebarVisible = true
    var fileBrowserSuspended = false
    @Published var detectedSystem: String?
    var initialDirectoryAttemptCompleted = false
    var isLocalTerminal: Bool { !isStartPage && host == nil }
    var readyForMonitoring: Bool { !isStartPage && (host == nil ? phase == .running : connected && initialDirectoryAttemptCompleted) }
    @Published private(set) var connected = false
    var prepareConnection: ((Session) -> Void)?
    var connectionJob: Task<Void, Never>?
    private var prepared = false
    private var authenticationLease: AuthenticationLease?
    @Published private(set) var phase = SessionPhase.ready
    @Published private(set) var terminalTitle = ""
    @Published private(set) var customTabTitle: String?
    @Published private(set) var dimensions = ""
    @Published var remotePath = "~/"
    @Published var remoteDirectory: RemoteDirectory?
    @Published var remoteSelection = Set<String>()
    @Published var listingError: String?
    @Published var listing: String? = nil
    @Published var listingBusy = false
    var fileMutationInProgress = false
    var listingJob: Task<Void, Never>?
    var listingRequest = UUID()
    var directoryReadInterrupted = false
    var onExit: ((Session) -> Void)?
    var onStart: ((Session) -> Void)?
    var onDisconnect: ((Session) -> Void)?
    var onReconnect: ((Session) -> Void)?
    private var disconnectNoticeShown = false
    private var terminationTask: Task<Void, Never>?
    private(set) var wasStopped = false
    var reconnectAttempt = 0
    var isAutomaticReconnect = false
    @Published var reconnectPending = false
    private(set) var connectedAt: ContinuousClock.Instant?
    @Published private(set) var restarting = false
    private var disconnectingTasks: [Task<Void, Never>] = []

    init(host: SSHHost?, commands: SSHCommands, fontSize: Double = 13, invocation: Invocation? = nil, authentication: AuthenticationContext? = nil, startPage: Bool = false, activity: TabActivity? = nil) throws {
        self.host = host; self.authentication = authentication; self.isStartPage = startPage
        self.activity = activity ?? TabActivity()
        self.detectedSystem = host?.detectedSystem
        self.invocation = try invocation ?? host.map { try commands.terminal($0) } ?? Invocation(executable: "/bin/zsh", arguments: ["-l"])
        if !startPage {
            terminal.refreshNativeColors()
            terminal.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            terminal.processDelegate = self
            terminal.reconnectOnReturn = { [weak self] in
                guard let self, !self.phase.isActive, !self.restarting, let reconnect = self.onReconnect else { return false }
                reconnect(self); return true
            }
        }
    }
    var defaultTabTitle: String { isStartPage ? T("起始页") : host?.name ?? "Local" }
    var tabTitle: String { customTabTitle ?? defaultTabTitle }
    func renameTab(_ value: String) {
        let singleLine = value.unicodeScalars.map { scalar -> String in
            let code = scalar.value
            return code < 0x20 || (0x7f...0x9f).contains(code) || code == 0x2028 || code == 0x2029 ? " " : String(scalar)
        }.joined()
        let title = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
        customTabTitle = title.isEmpty ? nil : String(title.prefix(160))
    }
    var title: String { isStartPage ? T("起始页") : host?.name ?? T("本地终端") }
    var isDisconnected: Bool { !isStartPage && !phase.isActive }
    var status: String { isStartPage ? T("选择主机以连接") : reconnectPending ? T("等待自动重连") : phase == .running && host != nil ? T("SSH 进程运行中") : host != nil && isDisconnected ? T("已断开") : phase.label }
    var statusHelp: String {
        switch phase {
        case .running where host != nil: return T("连接与认证结果显示在终端内；请完成指纹确认或登录。")
        case .exited(let code) where code == 255: return T("SSH 连接或认证失败，请查看终端错误，再重新连接。")
        case .failed(let message): return message
        default: return status
        }
    }
    func start() {
        guard !isStartPage, phase == .ready else { return }
        if host != nil, !prepared, let prepareConnection {
            phase = .connecting; prepareConnection(self); return
        }
        guard FileManager.default.isExecutableFile(atPath: invocation.executable) else {
            disconnectAuxiliary()
            phase = .failed(T("无法执行 %@，请检查文件是否存在以及执行权限。", invocation.executable))
            announceDisconnect()
            onExit?(self)
            return
        }
        phase = .running
        do {
            authenticationLease = try authentication?.lease(allowPrompts: !isAutomaticReconnect)
            let invocation = authenticationLease?.terminalInvocation(self.invocation) ?? self.invocation
            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = "xterm-256color"
            environment.merge(invocation.environment) { _, new in new }
            environment.merge(authenticationLease?.environment ?? [:]) { _, new in new }
            terminal.startProcess(executable: invocation.executable, args: invocation.arguments,
                                  environment: authentication == nil && invocation.environment.isEmpty ? nil : environment.map { "\($0.key)=\($0.value)" }, currentDirectory: host == nil ? FileManager.default.homeDirectoryForCurrentUser.path : nil)
            if terminal.process.running { onStart?(self) }
        } catch {
            authenticationLease?.close(); authenticationLease = nil
            disconnectAuxiliary()
            phase = .failed(error.localizedDescription); announceDisconnect(); onExit?(self)
        }
    }
    func connectionPrepared() {
        guard phase == .connecting else { return }
        prepared = true; connected = true; connectedAt = .now; phase = .ready; start()
    }
    func connectionFailed(_ error: String) {
        guard phase == .connecting else { return }
        phase = .failed(error); disconnectAuxiliary()
        announceDisconnect()
        onExit?(self)
    }
    func cancelListing() {
        if listingBusy && !fileMutationInProgress { directoryReadInterrupted = true }
        listingRequest = UUID(); listingJob?.cancel(); listingJob = nil; listingBusy = false; fileMutationInProgress = false
    }
    private func disconnectAuxiliary() {
        connected = false
        remoteDirectory = nil; remoteSelection = []; listingError = nil
        disconnectingTasks += [connectionJob, listingJob].compactMap { $0 }
        connectionJob?.cancel(); cancelListing(); monitor.stop()
        onDisconnect?(self)
    }
    func restart(host: SSHHost?, commands: SSHCommands, authentication: AuthenticationContext?, automatic: Bool = false, attempt: Int = 0, invocation requestedInvocation: Invocation? = nil) async throws {
        guard !isStartPage, !restarting else { return }
        let invocation = try requestedInvocation ?? host.map { try commands.terminal($0) } ?? Invocation(executable: "/bin/zsh", arguments: ["-l"])
        restarting = true; defer { restarting = false }
        stop()
        let pending = disconnectingTasks; disconnectingTasks.removeAll()
        for task in pending { await task.value }
        await monitor.stopAndWait()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while terminal.process.running || terminal.process.windingDown || phase == .stopping {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw SSHError.invalid(T("旧终端尚未退出，请稍后重连")) }
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
        terminal.beginConnectionBoundary()
        self.detectedSystem = host?.detectedSystem
        self.host = host; self.invocation = invocation; self.authentication = authentication
        prepared = false; wasStopped = false; connectedAt = nil; disconnectNoticeShown = false
        initialDirectoryAttemptCompleted = fileBrowserSuspended; remoteSelection = []; listingError = nil
        terminalTitle = ""; reconnectAttempt = attempt; isAutomaticReconnect = automatic
        phase = .ready; start()
    }
    func stop() {
        wasStopped = true; reconnectPending = false
        if isStartPage { phase = .exited(nil); return }
        disconnectAuxiliary()
        if phase == .connecting { phase = .exited(nil); announceDisconnect() }
        authenticationLease?.close(); authenticationLease = nil
        guard phase == .ready || phase == .running else { return }
        if phase == .ready { phase = .exited(nil); announceDisconnect(); return }
        phase = .stopping
        terminal.process.drainTimeout = 0.1
        terminal.terminate()
        let pid = terminal.process.shellPid
        // Interactive shells may ignore SIGTERM; terminal closure uses HUP.
        if pid > 0 { if getpgid(pid) == pid { kill(-pid, SIGHUP) } else { kill(pid, SIGHUP) } }
        // Retain the old session until termination has been observed; stale callbacks
        // belong to this Session, never to a replacement created by reconnect.
        terminationTask = Task { [self] in
            try? await Task.sleep(for: .milliseconds(250))
            let pid = terminal.process.shellPid
            if phase == .stopping, pid > 0 {
                if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
            }
            terminationTask = nil
        }
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        let value = "\(newCols) × \(newRows)"
        if dimensions != value { dimensions = value }
    }
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let value = String(title.prefix(160))
        if terminalTitle != value { terminalTitle = value }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        if case .failed = phase { return }
        authenticationLease?.close(); authenticationLease = nil
        disconnectAuxiliary()
        phase = .exited(exitCode)
        announceDisconnect()
        terminationTask?.cancel(); terminationTask = nil
        onExit?(self)
    }
    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        authenticationLease?.close(); authenticationLease = nil
        disconnectAuxiliary()
        phase = .failed(error.localizedDescription)
        announceDisconnect()
        terminationTask?.cancel(); terminationTask = nil
        onExit?(self)
    }
    private func announceDisconnect() {
        guard !isStartPage, !disconnectNoticeShown else { return }
        disconnectNoticeShown = true
        let detail: String
        switch phase {
        case .failed(let message): detail = String(message.suffix(8192))
        case .exited(let code): detail = code.map { T("退出码：%d", $0) } ?? ""
        default: detail = ""
        }
        let title = T(host == nil ? "终端已结束" : "连接已断开")
        terminal.showDisconnectNotice(title + (detail.isEmpty ? "" : " · " + detail.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")), hint: T(host == nil ? "按回车重新打开" : "按回车重新连接"))
    }
}
