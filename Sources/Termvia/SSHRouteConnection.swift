import Foundation
import TermviaCore

/// Owns foreground jump masters and private proxy snapshots for one terminal.
/// No shell passwords or user-editable ProxyCommand strings are persisted.
@MainActor final class SSHRouteConnection {
    let root: URL
    private let wireGuardPool: WireGuardPool
    private var masters: [Task<Void, Never>] = []
    private var leases: [AuthenticationLease] = []
    private var wireGuardLeases: [WireGuardPool.Lease] = []
    private var closed = false
    init(wireGuardPool: WireGuardPool? = nil) throws {
        self.wireGuardPool = wireGuardPool ?? WireGuardPool()
        root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("tv-route-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func proxy(_ proxy: SSHProxy, password: String, target: SSHHost) async throws -> String {
        if proxy.kind == .wireguard {
            let lease = try await wireGuardPool.acquire(proxy: proxy, password: password, target: target)
            guard !closed else { lease.close(); throw CancellationError() }
            wireGuardLeases.append(lease); return lease.command
        }
        struct Snapshot: Encodable { let proxy: SSHProxy; let password: String; let target: String; let port: Int }
        let file = root.appendingPathComponent(UUID().uuidString + ".json")
        let data = try JSONEncoder().encode(Snapshot(proxy: proxy, password: password, target: target.address, port: target.port))
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw SSHError.invalid("无法保存代理配置") }
        let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent(proxy.kind == .wireguard ? "termvia-wireguard" : "termvia-proxy")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw SSHError.invalid("代理辅助程序缺失，请重新构建应用") }
        // OpenSSH expands percent tokens before passing ProxyCommand to the shell.
        return [helper.path, file.path].map { SSHRoute.shellQuote($0.replacingOccurrences(of: "%", with: "%%")) }.joined(separator: " ")
    }
    func jump(_ host: SSHHost, to target: SSHHost, commands: SSHCommands, authentication: AuthenticationContext, allowPrompts: Bool) async throws -> String {
        let socket = root.appendingPathComponent("s\(masters.count)").path
        let lease = try authentication.lease(allowPrompts: allowPrompts)
        leases.append(lease)
        let invocation = try commands.connectionCheck(host, controlPath: socket)
        let state = MasterState()
        let task = Task {
            do { let reply = try await lease.run(invocation); state.failure = reply.output.isEmpty ? T("跳板机连接已结束") : reply.output }
            catch { state.failure = error.localizedDescription }
        }
        masters.append(task)
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while true {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            if let failure = state.failure { throw SSHError.invalid(failure) }
            if FileManager.default.fileExists(atPath: socket) {
                let check = try await ProcessRunner().run(commands.controlCheck(host, controlPath: socket))
                if check.status == 0 { lease.confirmAuthentication(); break }
            }
            guard ContinuousClock.now < deadline else { throw SSHError.invalid("跳板机连接超时") }
            try await Task.sleep(for: .milliseconds(100))
        }
        // If the master disappears, never make an independent fallback connection.
        let destination = "\(host.user)@\(host.address.contains(":") ? "[\(host.address)]" : host.address)"
        let endpoint = "\(target.address.contains(":") ? "[\(target.address)]" : target.address):\(target.port)"
        return ["/usr/bin/ssh", "-F", "/dev/null", "-o", "ProxyCommand=/usr/bin/false", "-S", socket, "-p", String(host.port), "-W", endpoint, "--", destination]
            .map { SSHRoute.shellQuote($0.replacingOccurrences(of: "%", with: "%%")) }.joined(separator: " ")
    }
    func close() {
        guard !closed else { return }; closed = true
        for lease in leases { lease.close() }; leases.removeAll()
        let pending = masters; masters.removeAll(); for task in pending { task.cancel() }
        let directory = root, proxies = wireGuardLeases; wireGuardLeases.removeAll()
        Task { for task in pending { await task.value }; for proxy in proxies { proxy.close() }; try? FileManager.default.removeItem(at: directory) }
    }
    deinit {
        let pending = masters, proxies = wireGuardLeases, directory = root
        for task in pending { task.cancel() }
        Task { @MainActor in for task in pending { await task.value }; for proxy in proxies { proxy.close() }; try? FileManager.default.removeItem(at: directory) }
    }
    private final class MasterState { var failure: String? }
}

extension AppModel {
    func editorConnection(for original: SSHHost) async throws -> (SSHHost, AuthenticationContext, SSHRouteConnection) {
        let route = try SSHRouteConnection(wireGuardPool: wireGuardPool)
        do {
            let chain = try SSHRoute.chain(for: hosts.first { $0.id == original.id } ?? original, hosts: hosts, proxies: settings.proxies)
            var routed: SSHHost?
            for item in chain {
                try Task.checkCancellation()
                var next = try resolvedHost(item); next.transportCommand = nil
                if let previous = routed {
                    next.transportCommand = try await route.jump(previous, to: next, commands: commands, authentication: authentication(for: previous), allowPrompts: true)
                } else if case .proxy(let id) = item.upstream {
                    guard let proxy = settings.proxies.first(where: { $0.id == id }) else { throw SSHError.invalid("找不到代理服务器") }
                    let password = try FileSecretStore(directory: root.appendingPathComponent("proxy-secrets")).read(id) ?? ""
                    next.transportCommand = try await route.proxy(proxy, password: password, target: next)
                }
                routed = next
            }
            guard let host = routed else { throw SSHError.invalid("找不到上游跳板机") }
            return (host, try authentication(for: host), route)
        } catch { route.close(); throw error }
    }
}
