import Foundation
import TermviaCore

@MainActor struct TransferConnection {
    let commands: SSHCommands
    let transfer: Transfer
    var host: SSHHost { transfer.authentication?.host ?? transfer.host }
    func directory(_ path: String, operations: [SFTPOperation] = []) async throws -> RemoteDirectory {
        try Task.checkCancellation()
        let lease = try transfer.authentication?.lease(); defer { lease?.close() }
        let operation = SFTPOperation.batch(operations + [.list(path)])
        let directory: RemoteDirectory?
        if transfer.method == .scp {
            let invocation = try SSHFileClient.invocation(host, commands: commands, operation: operation)
            if let lease { directory = try await lease.performSSHFiles(invocation) }
            else { directory = try await SSHFileClient().perform(invocation) }
        } else {
            let invocation = try commands.sftpSubsystem(host)
            if let lease { directory = try await lease.performSFTP(operation, invocation: invocation) }
            else { directory = try await SFTPClient().perform(operation, invocation: invocation) }
        }
        guard let directory else { throw SSHError.invalid("无法读取目录") }
        lease?.confirmAuthentication()
        return directory
    }
    func run(_ invocation: Invocation) async throws {
        try Task.checkCancellation()
        let lease = try transfer.authentication?.lease(); defer { lease?.close() }
        let result: CommandResult
        if let lease { result = try await lease.run(invocation) }
        else { result = try await ProcessRunner().run(invocation) }
        try Task.checkCancellation()
        guard result.status == 0 else { throw SSHError.invalid(result.output) }
        lease?.confirmAuthentication()
    }
    func files(_ paths: [String], localRoot: URL) async throws {
        for start in stride(from: 0, to: paths.count, by: 64) {
            let invocations = try paths[start..<min(start + 64, paths.count)].map { try commands.transfer(host, local: localRoot.appendingPathComponent($0).path, remote: transfer.remote + "/" + $0, upload: transfer.upload, method: transfer.method) }
            if transfer.method == .sftp, var batch = invocations.first {
                batch.input = invocations.reduce(into: Data()) { $0.append($1.input ?? Data()) }
                try await run(batch)
            } else { for invocation in invocations { try await run(invocation) } }
        }
    }
}
