import Foundation

/// Single-file legacy SCP over an authenticated SSH exec channel.
/// Byte counters advance only after successful protocol writes/reads.
final class SCPStream {
    let input: FileHandle, output: FileHandle
    let check: () throws -> Void
    let control: FileTransferControl?
    init(input: FileHandle, output: FileHandle, check: @escaping () throws -> Void, control: FileTransferControl?) { self.input = input; self.output = output; self.check = check; self.control = control }
    private func read(_ count: Int) throws -> Data {
        var result = Data()
        while result.count < count { try check(); guard let data = try output.read(upToCount: count - result.count), !data.isEmpty else { throw SFTPFailure.closed("SCP") }; result.append(data) }
        return result
    }
    private func line() throws -> String {
        var bytes = Data()
        while bytes.count < 16384 { let byte = try read(1); if byte[0] == 10 { return String(decoding: bytes, as: UTF8.self) }; bytes.append(byte) }
        throw SFTPFailure.malformed
    }
    private func ack() throws {
        let byte = try read(1)[0]
        guard byte == 0 else { throw SSHError.invalid(try line()) }
    }
    private func sendAck() throws { try input.write(contentsOf: Data([0])) }
    func replaceFile(local: String, remote: String) throws {
        let url = URL(fileURLWithPath: local)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard let size = values.fileSize, size >= 0, values.isRegularFile == true, values.isSymbolicLink != true else { throw SFTPFailure.malformed }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard try read(1) == Data([0]) else { throw SFTPFailure.malformed }
        control?.beginFile(remote, size: UInt64(size))
        var left = size
        while left > 0 {
            try check()
            guard let data = try file.read(upToCount: min(left, 32768)), !data.isEmpty else { throw SFTPFailure.malformed }
            try input.write(contentsOf: data)
            left -= data.count; control?.advance(data.count)
        }
        guard try read(1) == Data([0]) else { throw SFTPFailure.malformed }
        // EOF or cancellation before this message leaves the destination untouched.
        try check()
        try input.write(contentsOf: Data("commit\n".utf8))
        // The commit is in flight. The transport gives the acknowledgement a
        // bounded grace period if cancellation arrives here.
        guard let acknowledgement = try output.read(upToCount: 1), !acknowledgement.isEmpty else {
            throw SFTPFailure.closed("SCP")
        }
        guard acknowledgement == Data([0]) else { throw SFTPFailure.malformed }
    }
    func transfer(local: String, remote: String, upload: Bool) throws {
        let url = URL(fileURLWithPath: local)
        if upload {
            let metadata = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard metadata.isRegularFile == true, metadata.isSymbolicLink != true else { throw SFTPFailure.malformed }
            let size = UInt64(max(0, metadata.fileSize ?? 0)), file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let mode = (try FileManager.default.attributesOfItem(atPath: local)[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o600
            let permissions = String(format: "%04o", mode & 0o777)
            try ack(); try input.write(contentsOf: Data("C\(permissions) \(size) \(url.lastPathComponent)\n".utf8)); try ack()
            control?.beginFile(remote, size: size)
            var left = size
            while left > 0 {
                try check(); guard let data = try file.read(upToCount: Int(min(left, 32768))), !data.isEmpty else { throw SFTPFailure.malformed }
                try input.write(contentsOf: data); left -= UInt64(data.count); control?.advance(data.count)
            }
            try sendAck(); try ack()
        } else {
            try sendAck()
            var record = try line()
            while record.hasPrefix("T") { try sendAck(); record = try line() }
            let fields = record.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, fields[0].range(of: "^C[0-7]{4}$", options: .regularExpression) != nil,
                  let size = UInt64(fields[1]), String(fields[2]) == (remote as NSString).lastPathComponent else { throw SFTPFailure.malformed }
            guard FileManager.default.createFile(atPath: local, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw SSHError.invalid("无法打开文件") }
            let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
            control?.beginFile(remote, size: size); try sendAck()
            var left = size
            while left > 0 { try check(); let data = try read(Int(min(left, 32768))); try file.write(contentsOf: data); left -= UInt64(data.count); control?.advance(data.count) }
            try ack(); try sendAck(); try file.synchronize()
            if control?.preserveFilePermissions != false, let mode = UInt32(fields[0].dropFirst(), radix: 8) { try FileManager.default.setAttributes([.posixPermissions: mode & 0o777], ofItemAtPath: local) }
        }
    }
}
