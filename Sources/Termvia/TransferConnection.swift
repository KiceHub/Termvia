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
        let result = try await execute(invocation, lease: lease)
        try Task.checkCancellation()
        guard result.status == 0 else { throw SSHError.invalid(result.output) }
        lease?.confirmAuthentication()
    }
    private func execute(_ invocation: Invocation, lease: AuthenticationLease?) async throws -> CommandResult {
        if let lease { return try await lease.run(invocation) }
        return try await ProcessRunner().run(invocation)
    }

    private func sftp(_ operation: SFTPOperation, invocation: Invocation, lease: AuthenticationLease?, control: FileTransferControl?) async throws {
        if let lease { _ = try await lease.performSFTP(operation, invocation: invocation, control: control) }
        else { _ = try await SFTPClient().perform(operation, invocation: invocation, control: control) }
    }

    private func overwriteSFTP(local: String, remote: String, subsystem: Invocation, lease: AuthenticationLease?) async throws {
        let overwrite = try RemoteUpload.Overwrite(remote: remote)
        let inspect = try commands.execute(host, command: overwrite.inspectCommand)
        let reply = try await execute(inspect, lease: lease)
        let lines = reply.output.split(whereSeparator: \.isNewline)
        guard reply.status == 0, lines.count == 1, let version = lines.first else {
            throw RemoteUpload.failure(reply.output, remote: remote)
        }
        do {
            let publish = try commands.execute(host, command: overwrite.publishCommand(version: String(version)))
            try await sftp(.stageUpload(local: local, remote: remote, directory: overwrite.directory),
                           invocation: subsystem, lease: lease, control: transfer.control)
            try Task.checkCancellation()
            // Once publication starts, wait for the server's response even
            // if the transfer is cancelled while the atomic rename is in flight.
            let commit = Task { try await execute(publish, lease: lease) }
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                commit.cancel()
            }
            defer { timeout.cancel() }
            let result = try await commit.value
            guard result.status == 0 else { throw RemoteUpload.failure(result.output, remote: remote) }
        } catch {
            // The server normally cleans up after publish. If publication
            // could not start, remove the private staging entry over SFTP.
            let cleanup = Task {
                let file = overwrite.directory + "/file"
                try? await sftp(.removeFile(file), invocation: subsystem, lease: lease, control: nil)
                try? await sftp(.removeDirectory(overwrite.directory), invocation: subsystem, lease: lease, control: nil)
            }
            await cleanup.value
            throw error
        }
    }
    func file(local: String, remote: String, upload: Bool, overwrite: Bool? = nil) async throws {
        _ = try commands.transfer(host, local: local, remote: remote, upload: upload, method: transfer.method)
        let lease = try transfer.authentication?.lease(); defer { lease?.close() }
        if upload && transfer.editorOwned {
            guard let digest = transfer.editorBaseDigest else { throw SFTPFailure.malformed }
            let file = URL(fileURLWithPath: local)
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= 0 else { throw SFTPFailure.malformed }
            let request = try RemoteEditorSave.upload(remote: remote, size: UInt64(size), expectedDigest: digest)
            var invocation = try commands.execute(host, command: request.command)
            invocation.input = request.input
            if let lease { try await lease.performSCP(local: local, remote: remote, upload: true, invocation: invocation, control: transfer.control, editorSave: true) }
            else { try await SFTPClient().performSCP(local: local, remote: remote, upload: true, invocation: invocation, control: transfer.control, editorSave: true) }
        } else if transfer.method == .sftp {
            let invocation = try commands.sftpSubsystem(host)
            if upload && (overwrite ?? transfer.overwrite) {
                try await overwriteSFTP(local: local, remote: remote, subsystem: invocation, lease: lease)
            } else {
                let operation: SFTPOperation = upload ? .uploadFile(local: local, remote: remote) : .downloadFile(remote: remote, local: local)
                try await sftp(operation, invocation: invocation, lease: lease, control: transfer.control)
            }
        } else {
            let command = upload ? try RemoteUpload.scpCommand(remote: remote, overwrite: overwrite ?? transfer.overwrite)
                                 : "scp -f -- " + SSHRoute.shellQuote(remote)
            let invocation = try commands.execute(host, command: command)
            if let lease {
                try await lease.performSCP(local: local, remote: remote, upload: upload, invocation: invocation,
                                           control: transfer.control, stagedUpload: upload)
            } else {
                try await SFTPClient().performSCP(local: local, remote: remote, upload: upload, invocation: invocation,
                                                control: transfer.control, stagedUpload: upload)
            }
        }
        lease?.confirmAuthentication()
    }
    func fileBatch(_ items: [(local: String, remote: String)], approvedOverwrites: Set<String> = []) async throws {
        if transfer.method == .scp || (transfer.upload && items.contains { approvedOverwrites.contains($0.remote) }) {
            for item in items {
                try await file(local: item.local, remote: item.remote, upload: transfer.upload, overwrite: approvedOverwrites.contains(item.remote))
            }
            return
        }
        let lease = try transfer.authentication?.lease(); defer { lease?.close() }
        let operation = SFTPOperation.batch(items.map {
            transfer.upload ? .uploadFile(local: $0.local, remote: $0.remote)
                            : .downloadFile(remote: $0.remote, local: $0.local)
        })
        let invocation = try commands.sftpSubsystem(host)
        try await sftp(operation, invocation: invocation, lease: lease, control: transfer.control)
        lease?.confirmAuthentication()
    }
    func files(_ paths: [String], localRoot: URL, approvedOverwrites: Set<String> = []) async throws {
        for start in stride(from: 0, to: paths.count, by: 64) {
            try Task.checkCancellation()
            try await fileBatch(paths[start..<min(start + 64, paths.count)].map { (localRoot.appendingPathComponent($0).path, transfer.remote + "/" + $0) },
                                approvedOverwrites: approvedOverwrites)
        }
    }
}
