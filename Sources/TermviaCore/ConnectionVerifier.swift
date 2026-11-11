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
        var invocation = try commands.connectionCheck(host, controlPath: path); invocation.environment = environment
        invocation.arguments.insert("-v", at: 0)
        let diagnostics = SSHConnectionDiagnostics()
        let master = invocation, check = try commands.controlCheck(host, controlPath: path)
        return try await withThrowingTaskGroup(of: Event.self) { group in
            group.addTask { .ended(try await ProcessRunner().run(master, onOutput: { diagnostics.feed($0) })) }
            group.addTask {
                while true {
                    try Task.checkCancellation()
                    if FileManager.default.fileExists(atPath: path) {
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
                group.cancelAll()
                // Drain the master before reading the final authenticated-method
                // diagnostic; socket readiness can race its last pipe read.
                do { try await group.waitForAll() } catch is CancellationError {}
                try Task.checkCancellation()
                return ConnectionVerification(status: 0, output: "authenticated", security: diagnostics.security)
            case .ended(let reply):
                return ConnectionVerification(status: reply.status == 0 ? 255 : reply.status, output: SSHConnectionDiagnostics.failureOutput(reply.output, suppressWarnings: commands.suppressWarnings), security: diagnostics.security)
            }
        }
    }
}
