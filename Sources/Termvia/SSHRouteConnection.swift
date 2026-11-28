import Foundation
import TermviaCore

/// Owns foreground SSH masters and private proxy snapshots for one terminal.
/// No shell passwords or user-editable ProxyCommand strings are persisted.
@MainActor final class SSHRouteConnection {
    let id = UUID()
    let root: URL
    private let wireGuardPool: WireGuardPool
    private let trackCleanup: (@MainActor (Task<Void, Never>) -> Void)?
    private var masters: [Task<Void, Never>] = []
    private var leases: [AuthenticationLease] = []
    private var wireGuardLeases: [WireGuardPool.Lease] = []
    private var closed = false
    private var disposed = false
    private var borrowers = 0
    private(set) var loginOutput = ""

    /// File editors outlive a terminal disconnect and own in-flight cleanup.
    @MainActor final class Lease {
        private var route: SSHRouteConnection?

        fileprivate init(route: SSHRouteConnection) { self.route = route }

        func close() {
            guard let route else { return }
            self.route = nil
            route.releaseEditor()
        }

        deinit {
            if let route { Task { @MainActor in route.releaseEditor() } }
        }
    }

    init(wireGuardPool: WireGuardPool? = nil, trackCleanup: (@MainActor (Task<Void, Never>) -> Void)? = nil) throws {
        self.wireGuardPool = wireGuardPool ?? WireGuardPool()
        self.trackCleanup = trackCleanup
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

    func authenticateHost(_ host: SSHHost, commands: SSHCommands, authentication: AuthenticationContext,
                          allowPrompts: Bool) async throws -> SSHConnectionSecurity {
        let path = root.appendingPathComponent("s\(masters.count)").path
        let lease = try authentication.lease(allowPrompts: allowPrompts)
        let state = MasterVerification()
        let task = Task {
            do {
                let result = try await lease.holdControlMaster(commands: commands, path: path) { verification in
                    await state.authenticated(verification)
                }
                state.failure = SSHRouteVerificationFailure(host: host, result: result)
            } catch {
                state.failure = error
            }
        }
        leases.append(lease); masters.append(task)
        do {
            while !closed {
                try Task.checkCancellation()
                if let failure = state.failure { throw failure }
                if let verification = state.verification {
                    lease.confirmAuthentication()
                    authentication.useControlMaster(at: path)
                    loginOutput = verification.output
                    return verification.security
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw CancellationError()
        } catch {
            task.cancel()
            lease.close()
            throw error
        }
    }
    func close() {
        guard !closed else { return }
        closed = true
        disposeIfUnused()
    }

    func retainForEditor() throws -> Lease {
        guard !closed else { throw CancellationError() }
        borrowers += 1
        return Lease(route: self)
    }

    private func releaseEditor() {
        borrowers -= 1
        disposeIfUnused()
    }

    private func disposeIfUnused() {
        guard closed, borrowers == 0, !disposed else { return }
        disposed = true
        for lease in leases { lease.close() }; leases.removeAll()
        let pending = masters; masters.removeAll(); for task in pending { task.cancel() }
        let directory = root, proxies = wireGuardLeases; wireGuardLeases.removeAll()
        let cleanup = Task {
            for task in pending { await task.value }
            for proxy in proxies { proxy.close() }
            try? FileManager.default.removeItem(at: directory)
        }
        trackCleanup?(cleanup)
    }
    deinit {
        guard !disposed else { return }
        let pending = masters, proxies = wireGuardLeases, directory = root
        for task in pending { task.cancel() }
        Task { @MainActor in for task in pending { await task.value }; for proxy in proxies { proxy.close() }; try? FileManager.default.removeItem(at: directory) }
    }
    private final class MasterState { var failure: String? }
    @MainActor private final class MasterVerification {
        var verification: ConnectionVerification?
        var failure: Error?
        func authenticated(_ value: ConnectionVerification) { verification = value }
    }
}

struct SSHRouteVerificationFailure: LocalizedError {
    let host: SSHHost
    let result: ConnectionVerification
    var errorDescription: String? { result.output }
}

extension AppModel {
    func editorConnection(for session: Session) throws -> (SSHHost, AuthenticationContext, SSHRouteConnection.Lease) {
        guard session.connected, !session.activity.isClosed, let host = session.host,
              let authentication = session.authentication, let route = session.routeConnection else {
            throw CancellationError()
        }
        return (host, authentication, try route.retainForEditor())
    }

    func connectRoute(for original: SSHHost, allowPrompts: Bool) async throws
        -> (SSHHost, AuthenticationContext, SSHRouteConnection, SSHConnectionSecurity) {
        let chain = try SSHRoute.chain(for: hosts.first { $0.id == original.id } ?? original, hosts: hosts, proxies: settings.proxies)
        if !legacyIPv6TrustFailures.isEmpty {
            let store = KnownHostsStore(url: URL(fileURLWithPath: commands.knownHosts))
            for item in chain where item.address.contains(":") {
                if let failure = legacyIPv6TrustFailures[try store.key(for: item)] { throw SSHError.invalid(failure) }
            }
        }
        let route = try SSHRouteConnection(wireGuardPool: wireGuardPool) { [weak self] cleanup in
            self?.trackRouteCleanup(cleanup)
        }
        do {
            var jump: ((SSHHost) -> String)?
            for (index, item) in chain.enumerated() {
                let final = index == chain.count - 1
                let proxy: SSHProxy?
                if case .proxy(let id) = item.upstream {
                    guard let configured = settings.proxies.first(where: { $0.id == id }) else { throw SSHError.invalid("找不到代理服务器") }
                    proxy = configured
                } else { proxy = nil }
                let password = try proxy.flatMap { try proxySecret($0.id) } ?? ""
                // WireGuard's helper resolves locally. Other proxies and the
                // jump server need the original name for their own resolver.
                let upstreamResolves = jump != nil || proxy.map { $0.kind != .wireguard } == true
                let addresses: [String]
                if upstreamResolves { addresses = [item.address] }
                else {
                    do { addresses = try await SSHAddressResolver.addresses(for: item.address) }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        guard proxy?.kind == .wireguard else { throw error }
                        addresses = [item.address]
                    }
                }
                for (attempt, address) in addresses.enumerated() {
                    try Task.checkCancellation()
                    var host = try resolvedHost(item)
                    let scoped = item.address.contains(":") && item.address.contains("%")
                    host.connectionEndpoint = address == item.address && !scoped ? nil : address
                    host.transportCommand = nil
                    host.controlPath = nil
                    do {
                        if let jump { host.transportCommand = jump(host) }
                        else if let proxy { host.transportCommand = try await route.proxy(proxy, password: password, target: host) }
                        let authentication = try self.authentication(for: host)
                        if final {
                            let security = try await route.authenticateHost(host, commands: commands, authentication: authentication,
                                                                            allowPrompts: allowPrompts)
                            return (authentication.host, authentication, route, security)
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
