import AppKit
import TermviaCore

@MainActor final class AuthenticationPrompts {
    weak var window: NSWindow?
    private struct Pending {
        let id: UUID; let scope: UUID; let host: String; let request: AskpassRequest
        let continuation: CheckedContinuation<String?, Never>
    }
    private var pending: [Pending] = []
    private var current: Pending?
    private var alert: NSAlert?
    private var retry: Task<Void, Never>?
    func ask(_ request: AskpassRequest, host: String, scope: UUID) async -> String? {
        await withCheckedContinuation { continuation in
            pending.append(Pending(id: UUID(), scope: scope, host: host, request: request, continuation: continuation))
            presentNext()
        }
    }
    private func presentNext() {
        guard current == nil, !pending.isEmpty else { return }
        guard let window else {
            let waiting = pending; pending = []; for item in waiting { item.continuation.resume(returning: nil) }; return
        }
        guard window.attachedSheet == nil else {
            if retry == nil {
                retry = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    self?.retry = nil; self?.presentNext()
                }
            }
            return
        }
        let item = pending.removeFirst(); current = item
        let alert = NSAlert(); self.alert = alert
        alert.messageText = item.request.isHostKeyConfirmation ? T("信任此服务器公钥？") : T("连接 %@", item.host)
        alert.informativeText = item.request.prompt
        let confirm = item.request.isHostKeyConfirmation || item.request.hint == "confirm"
        let notification = item.request.hint == "none"
        let field: NSSecureTextField?
        if confirm || notification { field = nil }
        else {
            let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
            input.placeholderString = T("密码或密钥口令")
            alert.accessoryView = input; field = input
        }
        alert.addButton(withTitle: T(item.request.isHostKeyConfirmation ? "信任并连接" : confirm ? "允许" : notification ? "确定" : "连接"))
        if !notification { alert.addButton(withTitle: T("取消")) }
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, self.current?.id == item.id else { return }
                self.current = nil; self.alert = nil
                let value: String? = response == .alertFirstButtonReturn ? (confirm ? "yes" : notification ? "" : field?.stringValue) : nil
                item.continuation.resume(returning: value)
                self.presentNext()
            }
        }
        if let field { alert.window.makeFirstResponder(field) }
    }
    func cancel(scope: UUID) {
        let removed = pending.filter { $0.scope == scope }; pending.removeAll { $0.scope == scope }
        for item in removed { item.continuation.resume(returning: nil) }
        if current?.scope == scope, let alert, let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .cancel)
        }
    }
    func cancelAll() {
        retry?.cancel(); retry = nil
        let removed = pending; pending = []
        for item in removed { item.continuation.resume(returning: nil) }
        if let alert, let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .cancel) }
    }
}

@MainActor final class AuthenticationContext {
    let host: SSHHost
    private let prompts: AuthenticationPrompts
    private var secret: String?
    private var passphrase: String?
    private var confirmedPassphrase: String?
    private var pendingPassphrase: String?
    private var secretVersion: UInt64 = 0
    private var pendingPersistence: String?
    private let onSecret: ((String) -> Void)?
    private let ppkHelper: URL?
    private var leaseScopes = Set<UUID>()
    private var ppkIdentity: PPKIdentity?
    private var ppkInfo: PPKConverter.Info?
    private var ppkReady = false
    private var ppkTask: Task<Void, Error>?
    private var ppkGeneration = UUID()
    private var ppkAttempt: Attempt?
    private var ppkScope = UUID()
    init(host: SSHHost, secret: String?, prompts: AuthenticationPrompts, ppkHelper: URL? = nil, onSecret: ((String) -> Void)? = nil) {
        self.host = host; self.prompts = prompts; self.onSecret = onSecret
        self.ppkHelper = ppkHelper
        let values = LoginSecrets(stored: secret, method: host.authentication ?? .automatic)
        self.secret = host.authentication == .privateKey ? (values.passphrase.isEmpty ? nil : values.passphrase) : (values.password.isEmpty ? nil : values.password)
        passphrase = values.passphrase; confirmedPassphrase = values.passphrase
    }
    func replaceCachedSecret(_ value: String?) {
        secretVersion &+= 1
        let values = LoginSecrets(stored: value, method: host.authentication ?? .automatic)
        secret = host.authentication == .privateKey ? (values.passphrase.isEmpty ? nil : values.passphrase) : (values.password.isEmpty ? nil : values.password)
        passphrase = values.passphrase; confirmedPassphrase = values.passphrase; pendingPersistence = nil; pendingPassphrase = nil
    }
    private func confirmAuthentication(_ attempt: Attempt) {
        guard !attempt.cancelled, attempt.version == secretVersion else { return }
        let passwordChanged = attempt.suppliedSecret != nil && pendingPersistence == attempt.suppliedSecret
        let passphraseChanged = !attempt.passwordRequested && attempt.suppliedPassphrase != nil && pendingPassphrase == attempt.suppliedPassphrase
        guard passwordChanged || passphraseChanged else { return }
        if passphraseChanged { confirmedPassphrase = attempt.suppliedPassphrase }
        pendingPersistence = nil; pendingPassphrase = nil
        if host.authentication == .keyAndPassword {
            if let value = try? LoginSecrets(password: secret ?? "", passphrase: confirmedPassphrase ?? "").stored(method: .keyAndPassword) { onSecret?(value) }
        } else if let value = attempt.suppliedSecret { onSecret?(value) }
    }
    private final class Attempt {
        var offered = false; var offeredPassphrase = false; var passwordRequested = false; var cancelled = false
        var suppliedSecret: String?; var suppliedPassphrase: String?; var version: UInt64?
    }
    private final class SecretQuestion {
        let id = UUID()
        var scopes = Set<UUID>()
        var task: Task<String?, Never>?
    }
    private var pendingSecret: SecretQuestion?
    func lease(helper: URL? = nil, allowPrompts: Bool = true) throws -> AuthenticationLease {
        let helper = helper ?? Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("termvia-askpass")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw SSHError.invalid("认证辅助程序缺失，请重新构建应用") }
        let scope = UUID(), attempt = Attempt()
        let server = try AskpassServer { [self] request in await respond(request, attempt: attempt, scope: scope, allowPrompts: allowPrompts) }
        leaseScopes.insert(scope)
        return AuthenticationLease(server: server, helper: helper, onAuthenticated: { [weak self] in
            self?.confirmAuthentication(attempt)
            if !attempt.passwordRequested, let ppk = self?.ppkAttempt { self?.confirmAuthentication(ppk) }
        }, prepareHost: { [self] in
            try await preparePPK(allowPrompts: allowPrompts)
            return preparedHost()
        }, prepareInvocation: { [self] invocation in
            try await preparePPK(allowPrompts: allowPrompts)
            return rewriteIdentity(invocation)
        }, preparedInvocation: { [self] in rewriteIdentity($0) }, onClose: { [weak self] in
            attempt.cancelled = true; self?.cancelRequest(scope: scope)
            guard let self else { return }
            self.leaseScopes.remove(scope)
            if self.leaseScopes.isEmpty {
                self.ppkAttempt?.cancelled = true; self.cancelRequest(scope: self.ppkScope)
                self.ppkTask?.cancel(); self.ppkTask = nil
                self.ppkIdentity = nil; self.ppkInfo = nil; self.ppkReady = false; self.ppkAttempt = nil; self.ppkGeneration = UUID(); self.ppkScope = UUID()
            }
        })
    }
    private func preparedHost() -> SSHHost {
        var result = host
        if ppkInfo != nil, ppkReady {
            result.identity = ppkIdentity?.key.path ?? ""
            if ppkIdentity == nil { result.authentication = .password }
        }
        return result
    }
    private func rewriteIdentity(_ invocation: Invocation) -> Invocation {
        guard ppkInfo != nil, ppkReady else { return invocation }
        var result = invocation, arguments: [String] = []
        var index = 0
        while index < result.arguments.count {
            if result.arguments[index] == "-o", index + 1 < result.arguments.count, result.arguments[index + 1].hasPrefix("IdentityFile=") {
                if let identity = ppkIdentity {
                    let path = identity.key.path.replacingOccurrences(of: "%", with: "%%").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    arguments += ["-o", "IdentityFile=\"\(path)\""]
                }
                index += 2
            } else { arguments.append(result.arguments[index]); index += 1 }
        }
        if ppkIdentity == nil { arguments.insert(contentsOf: ["-o", "PreferredAuthentications=password,keyboard-interactive"], at: 0) }
        result.arguments = arguments; return result
    }
    private func preparePPK(allowPrompts: Bool) async throws {
        try Task.checkCancellation()
        guard !leaseScopes.isEmpty else { throw CancellationError() }
        if ppkReady { return }
        if ppkInfo == nil {
            do { ppkInfo = try PPKConverter.inspect(host.identity) }
            catch {
                if host.authentication == .keyAndPassword, secret?.isEmpty == false {
                    ppkInfo = PPKConverter.Info(source: URL(fileURLWithPath: host.identity), encrypted: false, bytes: Data())
                    ppkReady = true; return
                }
                throw error
            }
        }
        guard let info = ppkInfo else { return }
        let generation = ppkGeneration
        let worker: Task<Void, Error>
        if let ppkTask { worker = ppkTask }
        else {
            let attempt = Attempt(); ppkAttempt = attempt
            worker = Task {
                let request = AskpassRequest(token: "", prompt: "Enter passphrase for key '\(host.identity)':")
                for retry in 0..<3 {
                    try Task.checkCancellation()
                    let pass: String
                    if info.encrypted {
                        guard let value = await respond(request, attempt: attempt, scope: ppkScope, allowPrompts: allowPrompts) else { throw SSHError.invalid(T("认证已取消或密钥口令不可用")) }
                        pass = value
                    } else { pass = "" }
                    do {
                        let converted = try await PPKConverter.convert(info, passphrase: pass, helper: ppkHelper)
                        try Task.checkCancellation()
                        guard ppkGeneration == generation else { throw CancellationError() }
                        ppkIdentity = converted; ppkReady = true; return
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        if host.authentication == .keyAndPassword, secret?.isEmpty == false {
                            guard ppkGeneration == generation else { throw CancellationError() }
                            ppkReady = true; return
                        }
                        if !info.encrypted || !allowPrompts || retry == 2 { throw error }
                    }
                }
            }
            ppkTask = worker
        }
        defer { if ppkGeneration == generation { ppkTask = nil } }
        try await worker.value
        try Task.checkCancellation()
    }
    private func cancelRequest(scope: UUID) {
        prompts.cancel(scope: scope)
        if let question = pendingSecret {
            question.scopes.remove(scope)
            if question.scopes.isEmpty {
                pendingSecret = nil
                question.task?.cancel(); prompts.cancel(scope: question.id)
            }
        }
    }
    private func sharedSecret(_ request: AskpassRequest, scope: UUID) async -> String? {
        let question: SecretQuestion
        if let pendingSecret { question = pendingSecret }
        else {
            question = SecretQuestion(); pendingSecret = question
            let version = secretVersion
            question.task = Task { [weak self, weak question] in
                guard let self, let question, !Task.isCancelled, !question.scopes.isEmpty else { return nil }
                let value = await self.prompts.ask(request, host: "\(self.host.user)@\(self.host.address):\(self.host.port)", scope: question.id)
                if self.pendingSecret?.id == question.id { self.pendingSecret = nil }
                if self.secretVersion == version, let value, !value.isEmpty, !question.scopes.isEmpty, (try? validateLoginSecret(value)) != nil { self.secret = value; self.pendingPersistence = value }
                return value
            }
        }
        question.scopes.insert(scope)
        return await question.task?.value
    }
    private func respond(_ request: AskpassRequest, attempt: Attempt, scope: UUID, allowPrompts: Bool) async -> String? {
        guard !attempt.cancelled else { return nil }
        if host.authentication == .keyAndPassword {
            var keyHost = host; keyHost.authentication = .privateKey
            if keyHost.acceptsSecretPrompt(request) {
                if !attempt.offeredPassphrase {
                    attempt.offeredPassphrase = true; attempt.version = secretVersion
                    return passphrase ?? ""
                }
                guard allowPrompts else { return nil }
                let version = secretVersion
                let value = await prompts.ask(request, host: "\(host.user)@\(host.address)", scope: scope)
                guard !attempt.cancelled, version == secretVersion else { return nil }
                if let value { passphrase = value; pendingPassphrase = value; attempt.suppliedPassphrase = value; attempt.version = version }
                return value
            }
        }
        let matches = host.acceptsSecretPrompt(request)
        if matches, host.authentication == .keyAndPassword {
            // Password fallback proves no candidate key passphrase. Retain the
            // last saved one rather than persisting a failed key attempt.
            attempt.passwordRequested = true; attempt.suppliedPassphrase = nil
            passphrase = confirmedPassphrase; pendingPassphrase = nil
        }
        if matches, !attempt.offered, let secret {
            attempt.offered = true; attempt.suppliedSecret = secret; attempt.version = secretVersion
            return secret
        }
        guard allowPrompts else { return nil }
        if matches { attempt.offered = true }
        let value: String?
        if matches { value = await sharedSecret(request, scope: scope) }
        else { value = await prompts.ask(request, host: "\(host.user)@\(host.address):\(host.port)", scope: scope) }
        guard !attempt.cancelled else { return nil }
        if value == nil { attempt.cancelled = true; return nil }
        if matches, value == secret { attempt.suppliedSecret = value; attempt.version = secretVersion }
        return value
    }
}

@MainActor final class AuthenticationLease {
    private let server: AskpassServer
    let environment: [String: String]
    private var onClose: (() -> Void)?
    private var onAuthenticated: (() -> Void)?
    private let prepareHost: () async throws -> SSHHost
    private let prepareInvocation: (Invocation) async throws -> Invocation
    private let preparedInvocation: (Invocation) -> Invocation
    init(server: AskpassServer, helper: URL, onAuthenticated: @escaping () -> Void, prepareHost: @escaping () async throws -> SSHHost, prepareInvocation: @escaping (Invocation) async throws -> Invocation, preparedInvocation: @escaping (Invocation) -> Invocation, onClose: @escaping () -> Void) {
        self.server = server; environment = server.environment(helper: helper); self.onClose = onClose; self.onAuthenticated = onAuthenticated
        self.prepareHost = prepareHost; self.prepareInvocation = prepareInvocation; self.preparedInvocation = preparedInvocation
    }
    func terminalInvocation(_ invocation: Invocation) -> Invocation { preparedInvocation(invocation) }
    func confirmAuthentication() { onAuthenticated?() }
    func run(_ invocation: Invocation, outputLimit: Int = 65536, onOutput: (@Sendable (Data) -> Void)? = nil) async throws -> CommandResult {
        guard onClose != nil else { throw CancellationError() }
        let server = server
        return try await withTaskCancellationHandler(operation: {
            var invocation = try await prepareInvocation(invocation)
            invocation.environment.merge(environment) { _, new in new }
            return try await ProcessRunner().run(invocation, outputLimit: outputLimit, onOutput: onOutput)
        }, onCancel: { [weak self] in
            // Unblock askpass before waiting for the child/its inherited pipes.
            server.close()
            Task { @MainActor in self?.close() }
        })
    }
    func verifyConnection(_ host: SSHHost, commands: SSHCommands) async throws -> ConnectionVerification {
        guard onClose != nil else { throw CancellationError() }
        let server = server
        return try await withTaskCancellationHandler(operation: {
            try await ConnectionVerifier.verify(prepareHost(), commands: commands, environment: environment)
        }, onCancel: { [weak self] in server.close(); Task { @MainActor in self?.close() } })
    }
    func performSFTP(_ operation: SFTPOperation, invocation: Invocation) async throws -> RemoteDirectory? {
        guard onClose != nil else { throw CancellationError() }
        let server = server
        return try await withTaskCancellationHandler(operation: {
            var invocation = try await prepareInvocation(invocation); invocation.environment.merge(environment) { _, new in new }
            return try await SFTPClient().perform(operation, invocation: invocation)
        }, onCancel: { [weak self] in
            server.close(); Task { @MainActor in self?.close() }
        })
    }
    func performSSHFiles(_ invocation: Invocation) async throws -> RemoteDirectory {
        guard onClose != nil else { throw CancellationError() }
        let server = server
        return try await withTaskCancellationHandler(operation: {
            var invocation = try await prepareInvocation(invocation)
            invocation.environment.merge(environment) { _, new in new }
            return try await SSHFileClient().perform(invocation)
        }, onCancel: { [weak self] in
            server.close(); Task { @MainActor in self?.close() }
        })
    }
    func close() { server.close(); onAuthenticated = nil; onClose?(); onClose = nil }
    deinit {
        server.close()
        if let onClose { Task { @MainActor in onClose() } }
    }
}
