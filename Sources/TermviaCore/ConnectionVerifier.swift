import Foundation

/// A foreground master authenticates without executing anything on the server.
/// Its private local control socket becomes available after authentication.
public enum ConnectionVerifier {
    private enum Event: Sendable { case authenticated, ended(CommandResult) }
    public static func verify(_ host: SSHHost, commands: SSHCommands, environment: [String: String] = [:]) async throws -> ConnectionVerification {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("termvia-connect-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("s").path
        return try await authenticate(host, commands: commands, controlPath: path, environment: environment, onAuthenticated: nil)
    }

    /// Keep the authenticated master running until it exits or the route cancels it.
    public static func holdMaster(_ host: SSHHost, commands: SSHCommands, controlPath: String, environment: [String: String],
                                  onAuthenticated: @escaping @Sendable (ConnectionVerification) async -> Void) async throws -> ConnectionVerification {
        try await authenticate(host, commands: commands, controlPath: controlPath, environment: environment, onAuthenticated: onAuthenticated)
    }

    private static func authenticate(_ host: SSHHost, commands: SSHCommands, controlPath: String, environment: [String: String],
                                     onAuthenticated: (@Sendable (ConnectionVerification) async -> Void)?) async throws -> ConnectionVerification {
        var invocation = try commands.connectionCheck(host, controlPath: controlPath); invocation.environment = environment
        invocation.arguments.insert("-v", at: 0)
        let diagnostics = SSHConnectionDiagnostics(captureLoginOutput: onAuthenticated != nil)
        let master = invocation, check = try commands.controlCheck(host, controlPath: controlPath)
        return try await withThrowingTaskGroup(of: Event.self) { group in
            group.addTask { .ended(try await ProcessRunner().run(master, onOutput: { diagnostics.feed($0) })) }
            group.addTask {
                while true {
                    try Task.checkCancellation()
                    if FileManager.default.fileExists(atPath: controlPath) {
                        let reply = try await ProcessRunner().run(check)
                        if reply.status == 0 { return .authenticated }
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            defer { group.cancelAll() }
            guard let event = try await group.next() else { throw CancellationError() }
            switch event {
            case .authenticated:
                guard let onAuthenticated else {
                    group.cancelAll()
                    // Drain diagnostics written before the control socket was opened.
                    do { try await group.waitForAll() } catch is CancellationError {}
                    try Task.checkCancellation()
                    return ConnectionVerification(status: 0, output: "authenticated", security: diagnostics.security)
                }
                try Task.checkCancellation()
                // The control socket can become ready before the output
                // reader has consumed OpenSSH's authentication diagnostic.
                let deadline = ContinuousClock.now.advanced(by: .milliseconds(200))
                var security = diagnostics.security
                while security.authentication == nil, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                    security = diagnostics.security
                }
                let output = diagnostics.takeLoginOutput(suppressWarnings: commands.suppressWarnings)
                await onAuthenticated(ConnectionVerification(status: 0, output: output, security: security))
                guard case .ended(let reply) = try await group.next() else { throw CancellationError() }
                return failure(reply, diagnostics: diagnostics, commands: commands)
            case .ended(let reply):
                return failure(reply, diagnostics: diagnostics, commands: commands)
            }
        }
    }

    private static func failure(_ reply: CommandResult, diagnostics: SSHConnectionDiagnostics, commands: SSHCommands) -> ConnectionVerification {
        ConnectionVerification(status: reply.status == 0 ? 255 : reply.status,
                               output: SSHConnectionDiagnostics.failureOutput(reply.output, suppressWarnings: commands.suppressWarnings),
                               security: diagnostics.security)
    }
}
