import Foundation
import TermviaCore

@MainActor struct TransferConnection {
    let commands: SSHCommands
    let transfer: Transfer
    var host: SSHHost { transfer.authentication?.host ?? transfer.host }
    func resolveEntry(_ path: String) async throws -> RemoteEntry {
        try Task.checkCancellation()
        let lease = try transfer.authentication?.lease(); defer { lease?.close() }
        let invocation = try transfer.method == .sftp ? commands.sftpSubsystem(host) : commands.execute(host, command: SSHFileClient.resolveCommand(path))
        let entry: RemoteEntry
        if let lease { entry = try await lease.resolveEntry(path, invocation: invocation, method: transfer.method) }
        else if transfer.method == .sftp { entry = try await SFTPClient().resolveEntry(path, invocation: invocation) }
        else { entry = try await SSHFileClient().resolveEntry(invocation) }
        lease?.confirmAuthentication(); return entry
    }
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
    func file(local: String, remote: String, upload: Bool) async throws {
        _ = try commands.transfer(host, local: local, remote: remote, upload: upload, method: transfer.method)
        let lease = try transfer.authentication?.lease(); defer { lease?.close() }
        let atomicReplacement = upload && transfer.editorOwned
        if transfer.method == .sftp {
            let operation: SFTPOperation = upload ? .uploadFile(local: local, remote: remote) : .downloadFile(remote: remote, local: local)
            let invocation = try commands.sftpSubsystem(host)
            if let lease { _ = try await lease.performSFTP(operation, invocation: invocation, control: transfer.control, atomicReplacement: atomicReplacement) }
            else { _ = try await SFTPClient().perform(operation, invocation: invocation, control: transfer.control, atomicReplacement: atomicReplacement) }
        } else {
            let command: String
            if atomicReplacement {
                let file = URL(fileURLWithPath: local)
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                command = try SSHFileClient.editorSaveCommand(remote: remote, size: UInt64(max(0, size)))
            } else { command = "scp " + (upload ? "-t" : "-f") + " -- " + SSHRoute.shellQuote(remote) }
            let invocation = try commands.execute(host, command: command)
            if let lease { try await lease.performSCP(local: local, remote: remote, upload: upload, invocation: invocation, control: transfer.control, atomicReplacement: atomicReplacement) }
            else { try await SFTPClient().performSCP(local: local, remote: remote, upload: upload, invocation: invocation, control: transfer.control, atomicReplacement: atomicReplacement) }
        }
        lease?.confirmAuthentication()
    }
    func fileBatch(_ items: [(local: String, remote: String)]) async throws {
        if transfer.method == .scp { for item in items { try await file(local: item.local, remote: item.remote, upload: transfer.upload) }; return }
        let lease = try transfer.authentication?.lease(); defer { lease?.close() }
        let operation = SFTPOperation.batch(items.map { transfer.upload ? .uploadFile(local: $0.local, remote: $0.remote) : .downloadFile(remote: $0.remote, local: $0.local) })
        let invocation = try commands.sftpSubsystem(host)
        if let lease { _ = try await lease.performSFTP(operation, invocation: invocation, control: transfer.control) }
        else { _ = try await SFTPClient().perform(operation, invocation: invocation, control: transfer.control) }
        lease?.confirmAuthentication()
    }
    func files(_ paths: [String], localRoot: URL) async throws {
        for start in stride(from: 0, to: paths.count, by: 64) {
            try Task.checkCancellation()
            try await fileBatch(paths[start..<min(start + 64, paths.count)].map { (localRoot.appendingPathComponent($0).path, transfer.remote + "/" + $0) })
        }
    }
}
