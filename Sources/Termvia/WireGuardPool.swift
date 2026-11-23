import Foundation
import CryptoKit
import TermviaCore

/// One device per proxy configuration, shared by all SSH/file/monitor channels.
/// Sharing avoids WireGuard peer endpoint roaming between concurrent processes.
@MainActor final class WireGuardPool {
    final class Lease {
        let command: String
        private var release: (@MainActor () -> Void)?
        init(command: String, release: @escaping @MainActor () -> Void) { self.command = command; self.release = release }
        @MainActor func close() { release?(); release = nil }
        deinit { let release = release; Task { @MainActor in release?() } }
    }
    private final class Running {
        let directory: URL, socket: URL, task: Task<Void, Never>, state: State
        var users = Set<UUID>()
        init(directory: URL, socket: URL, task: Task<Void, Never>, state: State) { self.directory = directory; self.socket = socket; self.task = task; self.state = state }
    }
    private final class State { var error: String? }
    private var closed = false
    private var entries: [String: Running] = [:]
    private var closing: [Task<Void, Never>] = []
    #if TERMVIA_DIAGNOSTICS
    var activeDeviceCount: Int { entries.count }
    #endif
    private let helperOverride: URL?
    private let root = URL(fileURLWithPath: "/private/tmp/tv-wg-" + UUID().uuidString.prefix(10))
    init(helper: URL? = nil) { helperOverride = helper }
    static func fingerprint(proxy: SSHProxy, password: String) throws -> String {
        struct Identity: Encodable { let address: String; let port: Int; let configuration: SSHProxy.WireGuard?; let secrets: WireGuardSecrets }
        let secrets = try JSONDecoder().decode(WireGuardSecrets.self, from: Data(password.utf8))
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let identity = try encoder.encode(Identity(address: proxy.address, port: proxy.port, configuration: proxy.wireGuard, secrets: secrets))
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }
    func acquire(proxy: SSHProxy, password: String, target: SSHHost) async throws -> Lease {
        try Task.checkCancellation(); guard !closed else { throw CancellationError() }
        struct Configuration: Encodable { let proxy: SSHProxy; let password: String }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(Configuration(proxy: proxy, password: password))
        let key = try Self.fingerprint(proxy: proxy, password: password)
        let helper = helperOverride ?? Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("termvia-wireguard")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw SSHError.invalid("代理辅助程序缺失，请重新构建应用") }
        if let old = entries[key], old.state.error != nil { entries[key] = nil; retire(old) }
        if entries[key] == nil {
            let folder = root.appendingPathComponent(String(UUID().uuidString.prefix(12)))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent("config.json"), socket = folder.appendingPathComponent("s")
            guard FileManager.default.createFile(atPath: file.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else { throw SSHError.invalid("无法保存代理配置") }
            let state = State()
            let task = Task {
                do { let result = try await ProcessRunner().run(Invocation(executable: helper.path, arguments: ["--serve", file.path, socket.path])); state.error = result.output.isEmpty ? T("WireGuard 连接已结束") : result.output }
                catch { state.error = error.localizedDescription }
            }
            entries[key] = Running(directory: folder, socket: socket, task: task, state: state)
        }
        guard let entry = entries[key] else { throw CancellationError() }
        let token = UUID(); entry.users.insert(token)
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !FileManager.default.fileExists(atPath: entry.socket.path) {
                try Task.checkCancellation()
                guard !closed, entries[key] === entry else { throw CancellationError() }
                if let error = entry.state.error { throw SSHError.invalid(error) }
                guard ContinuousClock.now < deadline else { throw SSHError.invalid("WireGuard 启动超时") }
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
            guard !closed, entries[key] === entry else { throw CancellationError() }
            let command = [helper.path, "--connect", entry.socket.path, target.connectionAddress, String(target.port)].map { SSHRoute.shellQuote($0.replacingOccurrences(of: "%", with: "%%")) }.joined(separator: " ")
            return Lease(command: command) { [weak self, weak entry] in
                guard let entry else { return }; self?.release(key: key, entry: entry, token: token)
            }
        } catch { release(key: key, entry: entry, token: token); throw error }
    }
    private func release(key: String, entry: Running, token: UUID) {
        entry.users.remove(token)
        guard entry.users.isEmpty, entries[key] === entry else { return }
        entries[key] = nil; retire(entry)
    }
    private func retire(_ entry: Running) {
        entry.task.cancel()
        closing.append(Task { await entry.task.value; try? FileManager.default.removeItem(at: entry.directory) })
    }
    func close() { closed = true; for entry in entries.values { retire(entry) }; entries.removeAll() }
    func finish() async {
        while !closing.isEmpty { let pending = closing; closing.removeAll(); for task in pending { await task.value } }
        if closed { try? FileManager.default.removeItem(at: root) }
    }
    deinit {
        let pending = entries.values.map(\.task) + closing, directory = root
        for entry in entries.values { entry.task.cancel() }
        Task { for task in pending { await task.value }; try? FileManager.default.removeItem(at: directory) }
    }
}
