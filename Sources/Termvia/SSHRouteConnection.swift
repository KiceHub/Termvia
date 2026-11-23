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
    private var verificationLease: AuthenticationLease?
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
        let data = try JSONEncoder().encode(Snapshot(proxy: proxy, password: password, target: target.connectionAddress, port: target.port))
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw SSHError.invalid("无法保存代理配置") }
        let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent(proxy.kind == .wireguard ? "termvia-wireguard" : "termvia-proxy")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw SSHError.invalid("代理辅助程序缺失，请重新构建应用") }
        // OpenSSH expands percent tokens before passing ProxyCommand to the shell.
        return [helper.path, file.path].map { SSHRoute.shellQuote($0.replacingOccurrences(of: "%", with: "%%")) }.joined(separator: " ")
    }
    func jump(_ host: SSHHost, commands: SSHCommands, authentication: AuthenticationContext, allowPrompts: Bool) async throws -> (SSHHost) -> String {
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
        do {
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
        } catch {
            lease.close()
            task.cancel()
            throw error
        }
        // If the master disappears, never make an independent fallback connection.
        return { target in
            let address = target.connectionAddress
            let endpoint = "\(address.contains(":") ? "[\(address)]" : address):\(target.port)"
            return ["/usr/bin/ssh", "-F", "/dev/null", "-o", "ProxyCommand=/usr/bin/false", "-S", socket, "-p", String(host.port), "-W", endpoint, "--", "\(host.user)@\(host.address)"]
                .map { SSHRoute.shellQuote($0.replacingOccurrences(of: "%", with: "%%")) }.joined(separator: " ")
        }
    }
    func close() {
        guard !closed else { return }; closed = true
        finishVerification()
        for lease in leases { lease.close() }; leases.removeAll()
        let pending = masters; masters.removeAll(); for task in pending { task.cancel() }
        let directory = root, proxies = wireGuardLeases; wireGuardLeases.removeAll()
        Task { for task in pending { await task.value }; for proxy in proxies { proxy.close() }; try? FileManager.default.removeItem(at: directory) }
    }
    /// The interactive terminal needs the converted PuTTY key to survive
    /// between verification and creation of its own authentication lease.
    func keepVerification(_ lease: AuthenticationLease) { verificationLease = lease }
    func finishVerification() {
        verificationLease?.close()
        verificationLease = nil
    }
    deinit {
        let pending = masters, proxies = wireGuardLeases, directory = root
        for task in pending { task.cancel() }
        Task { @MainActor in for task in pending { await task.value }; for proxy in proxies { proxy.close() }; try? FileManager.default.removeItem(at: directory) }
    }
    private final class MasterState { var failure: String? }
}

struct SSHRouteVerificationFailure: LocalizedError {
    let host: SSHHost
    let result: ConnectionVerification
    var errorDescription: String? { result.output }
}

extension AppModel {
    func editorConnection(for original: SSHHost) async throws -> (SSHHost, AuthenticationContext, SSHRouteConnection) {
        let (host, authentication, route, _) = try await connectRoute(for: original, allowPrompts: true, preferredEndpoint: original.connectionEndpoint)
        return (host, authentication, route)
    }

    func connectRoute(for original: SSHHost, allowPrompts: Bool, preferredEndpoint: String? = nil) async throws
        -> (SSHHost, AuthenticationContext, SSHRouteConnection, SSHConnectionSecurity) {
        let route = try SSHRouteConnection(wireGuardPool: wireGuardPool)
        do {
            let chain = try SSHRoute.chain(for: hosts.first { $0.id == original.id } ?? original, hosts: hosts, proxies: settings.proxies)
            var jump: ((SSHHost) -> String)?
            for (index, item) in chain.enumerated() {
                let final = index == chain.count - 1
                let proxy: SSHProxy?
                if case .proxy(let id) = item.upstream {
                    guard let configured = settings.proxies.first(where: { $0.id == id }) else { throw SSHError.invalid("找不到代理服务器") }
                    proxy = configured
                } else { proxy = nil }
                let password = try proxy.flatMap { try FileSecretStore(directory: root.appendingPathComponent("proxy-secrets")).read($0.id) } ?? ""
                // WireGuard's helper resolves locally. Other proxies and the
                // jump server need the original name for their own resolver.
                let upstreamResolves = jump != nil || proxy.map { $0.kind != .wireguard } == true
                let preferred = !upstreamResolves && final && item.address == original.address && item.port == original.port ? preferredEndpoint : nil
                var addresses: [String]
                if upstreamResolves { addresses = [item.address] }
                else {
                    do { addresses = try await SSHAddressResolver.addresses(for: item.address) }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        guard preferred != nil || proxy?.kind == .wireguard else { throw error }
                        addresses = [preferred ?? item.address]
                    }
                }
                if let preferred {
                    addresses.removeAll { $0 == preferred }
                    addresses.insert(preferred, at: 0)
                }
                for (attempt, address) in addresses.enumerated() {
                    try Task.checkCancellation()
                    var host = try resolvedHost(item)
                    host.connectionEndpoint = address == item.address ? nil : address
                    host.transportCommand = nil
                    do {
                        if let jump { host.transportCommand = jump(host) }
                        else if let proxy { host.transportCommand = try await route.proxy(proxy, password: password, target: host) }
                        let authentication = try self.authentication(for: host)
                        if final {
                            let lease = try authentication.lease(allowPrompts: allowPrompts)
                            do {
                                let result = try await lease.verifyConnection(host, commands: commands)
                                try Task.checkCancellation()
                                guard result.status == 0 else { throw SSHRouteVerificationFailure(host: host, result: result) }
                                lease.confirmAuthentication()
                                route.keepVerification(lease)
                                return (host, authentication, route, result.security)
                            } catch {
                                lease.close()
                                throw error
                            }
                        }
                        jump = try await route.jump(host, commands: commands, authentication: authentication, allowPrompts: allowPrompts)
                        break
                    } catch {
                        try Task.checkCancellation()
                        let detail = error.localizedDescription.lowercased()
                        let loginFailure = ["permission denied", "authentication failed", "host key", "identification has changed"]
                            .contains(where: { detail.contains($0) })
                        let transportFailure = AppSettings.isTransientConnectionFailure(detail)
                            || detail.contains("connect to host ") || detail.contains("connect failed") || detail.contains("proxy connection failed")
                        guard attempt + 1 < addresses.count, transportFailure, !loginFailure else { throw error }
                    }
                }
            }
            throw SSHError.invalid("找不到上游跳板机")
        } catch { route.close(); throw error }
    }
}
