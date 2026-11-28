import Foundation
import Darwin

public enum RemoteFileKind: String, Codable, Sendable { case file, directory, symbolicLink, other }
public struct RemoteEntry: Identifiable, Equatable, Codable, Sendable {
    public let name: String
    public let path: String
    public let kind: RemoteFileKind
    public let size: UInt64?
    public let modified: Date?
    public let linkTargetKind: RemoteFileKind?
    public var displayKind: RemoteFileKind { kind == .symbolicLink ? linkTargetKind ?? .symbolicLink : kind }
    public init(name: String, path: String, kind: RemoteFileKind, size: UInt64? = nil, modified: Date? = nil, linkTargetKind: RemoteFileKind? = nil) {
        self.name = name; self.path = path; self.kind = kind; self.size = size; self.modified = modified; self.linkTargetKind = linkTargetKind
    }
    public var id: String { Data(path.utf8).base64EncodedString() }
    public var sortSize: UInt64 { size ?? 0 }
    public var sortDate: Date { modified ?? .distantPast }
    public var displayName: String { name.replacingOccurrences(of: "\n", with: "↵").replacingOccurrences(of: "\r", with: "␍").replacingOccurrences(of: "\t", with: "⇥") }
}
public struct RemoteDirectory: Equatable, Codable, Sendable { public let path: String; public let entries: [RemoteEntry]; public init(path: String, entries: [RemoteEntry]) { self.path = path; self.entries = entries } }
public enum SFTPOperation: Sendable {
    case list(String), makeDirectory(String), makeFile(String), copyFile(String, String), rename(String, String), removeFile(String), removeDirectory(String), removeTree(String)
    case uploadFile(local: String, remote: String), stageUpload(local: String, remote: String, directory: String)
    case downloadFile(remote: String, local: String)
    indirect case batch([SFTPOperation])

    fileprivate var stagesUpload: Bool {
        switch self {
        case .uploadFile, .stageUpload: return true
        case .batch(let operations): return operations.contains { $0.stagesUpload }
        default: return false
        }
    }
}
public enum SFTPFailure: LocalizedError {
    case status(UInt32, String), malformed, unsupported, closed(String), tooManyEntries, timeout
    public var errorDescription: String? {
        switch self {
        case .status(let code, let message): return T("SFTP 错误 %d：%@", Int(code), String(message.prefix(2048)))
        case .malformed: return T("SFTP 返回了无效数据")
        case .unsupported: return T("服务器未提供兼容的 SFTP v3")
        case .closed(let detail): return T("SFTP 连接已关闭：%@", String(detail.prefix(2048)))
        case .tooManyEntries: return T("目录条目过多，请缩小目录范围")
        case .timeout: return T("文件操作超时，请重试")
        }
    }
}
public enum FilePaths {
    public static func child(_ name: String, in directory: String) throws -> String {
        guard directory.hasPrefix("/"), !directory.contains("\0"), !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw SSHError.invalid("请输入有效的单个文件名") }
        return (directory == "/" ? "/" : directory + "/") + name
    }
}

/// SFTP v3 framing over the system ssh subsystem. Directory names and paths
/// never pass through ls output parsing or a remote shell.
public final class SFTPClient: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var started = false
    private var cancelled = false
    private var timedOut = false
    private var allowsCleanupOnCancellation = false
    public init() {}
    public func cancel() { stop(timeout: false) }
    private func stop(timeout: Bool) {
        lock.lock()
        cancelled = true; timedOut = timedOut || timeout
        let child = process, allowCleanup = allowsCleanupOnCancellation && !timedOut
        lock.unlock()
        guard let child else { return }
        if allowCleanup {
            // Give a responsive channel time to acknowledge a commit or clean up its staging file.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if child.isRunning { ChildProcess.stop(child) } }
        } else { ChildProcess.stop(child) }
    }
    private func check() throws {
        lock.lock(); let cancel = cancelled, timeout = timedOut; lock.unlock()
        if timeout { throw SFTPFailure.timeout }; if cancel { throw CancellationError() }
    }
    public func perform(_ operation: SFTPOperation, invocation: Invocation, control: FileTransferControl? = nil) async throws -> RemoteDirectory? {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do { continuation.resume(returning: try run(operation, invocation: invocation, control: control)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { control?.cancel(); self.cancel() })
    }
    public func inspectFile(_ path: String, invocation: Invocation) async throws -> EditorFileInspection {
        try await query(invocation) { try $0.inspectFile(path) }
    }
    public func resolveEntry(_ path: String, invocation: Invocation) async throws -> RemoteEntry {
        try await query(invocation) { try $0.resolveEntry(path) }
    }
    private func query<Value: Sendable>(_ invocation: Invocation, read: @escaping (SFTPChannel) throws -> Value) async throws -> Value {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do {
                        var value: Value?
                        _ = try run(.batch([]), invocation: invocation, inspection: { value = try read($0) })
                        guard let value else { throw SFTPFailure.malformed }
                        continuation.resume(returning: value)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { self.cancel() })
    }
    public func performSCP(local: String, remote: String, upload: Bool, invocation: Invocation, control: FileTransferControl, editorSave: Bool = false, stagedUpload: Bool = false) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do {
                        _ = try run(.batch([]), invocation: invocation, control: control, scp: (local, remote, upload),
                                    editorSave: editorSave, stagedUpload: stagedUpload)
                        continuation.resume()
                    }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { control.cancel(); self.cancel() })
    }
    private func run(_ operation: SFTPOperation, invocation: Invocation, control: FileTransferControl? = nil,
                     scp: (String, String, Bool)? = nil, editorSave: Bool = false, stagedUpload: Bool = false,
                     inspection: ((SFTPChannel) throws -> Void)? = nil) throws -> RemoteDirectory? {
        try check()
        let child = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        child.executableURL = URL(fileURLWithPath: invocation.executable); child.arguments = invocation.arguments
        child.standardInput = input; child.standardOutput = output; child.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"; environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment.merge(invocation.environment) { _, new in new }; child.environment = environment
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        guard !started else { lock.unlock(); throw SSHError.invalid("进程执行器不可重复使用") }; started = true
        do { try child.run() } catch { lock.unlock(); throw error }
        process = child
        allowsCleanupOnCancellation = editorSave || stagedUpload || operation.stagesUpload
        lock.unlock()
        let errorBuffer = ErrorBuffer()
        DispatchQueue.global().async {
            while let data = try? errors.fileHandleForReading.read(upToCount: 4096), !data.isEmpty { errorBuffer.append(data) }
        }
        if control == nil {
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self, weak child] in
            guard let self, let child, child.isRunning else { return }; self.stop(timeout: true)
        }
        }
        defer {
            try? input.fileHandleForWriting.close()
            if editorSave || stagedUpload {
                // EOF lets the remote helper remove its private staging directory
                // when a save ends before commit. Bound the wait for an SSH peer.
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { ChildProcess.stop(child) }
            } else { ChildProcess.stop(child) }
            child.waitUntilExit()
            try? output.fileHandleForReading.close()
            lock.lock(); process = nil; lock.unlock()
        }
        do {
            let checkpoint = { [self] in try check(); try control?.checkpoint() }
            if let (local, remote, upload) = scp {
                let stream = SCPStream(input: input.fileHandleForWriting, output: output.fileHandleForReading, check: checkpoint, control: control)
                if editorSave {
                    if let prefix = invocation.input { try input.fileHandleForWriting.write(contentsOf: prefix) }
                    try stream.replaceFile(local: local, remote: remote)
                } else {
                    try stream.transfer(local: local, remote: remote, upload: upload, stagedUpload: stagedUpload)
                }
                control?.finish(); return nil
            }
            let channel = SFTPChannel(input: input.fileHandleForWriting, output: output.fileHandleForReading, check: checkpoint, control: control)
            try channel.initialize()
            if let inspection { try inspection(channel); try check(); return nil }
            let result = try channel.perform(operation)
            control?.finish()
            switch operation {
            case .uploadFile, .stageUpload: return result
            default: break
            }
            try check()
            return result
        } catch let recovery as RemoteEditorSave.RecoveryFailure {
            throw recovery
        } catch {
            try check()
            if case SFTPFailure.closed = error { throw SFTPFailure.closed(errorBuffer.text) }
            throw error
        }
    }
    private final class ErrorBuffer: @unchecked Sendable {
        private let lock = NSLock(); private var bytes = Data()
        func append(_ data: Data) { lock.lock(); bytes.append(data); if bytes.count > 16384 { bytes.removeFirst(bytes.count - 16384) }; lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
    }
}

enum SFTPField { case string(String), bytes(Data), integer(UInt32) }
struct SFTPReader {
    struct FileAttributes {
        let kind: RemoteFileKind, size: UInt64?, modified: Date?, mode: UInt32
    }
    let data: Data; var offset = 0
    mutating func byte() throws -> UInt8 { guard offset < data.count else { throw SFTPFailure.malformed }; defer { offset += 1 }; return data[offset] }
    mutating func integer() throws -> UInt32 {
        guard data.count - offset >= 4 else { throw SFTPFailure.malformed }
        var value: UInt32 = 0; for _ in 0..<4 { value = (value << 8) | UInt32(try byte()) }; return value
    }
    mutating func uint64() throws -> UInt64 { let high = try integer(), low = try integer(); return UInt64(high) << 32 | UInt64(low) }
    mutating func bytes() throws -> Data {
        let size = Int(try integer()); guard size <= data.count - offset else { throw SFTPFailure.malformed }
        defer { offset += size }; return data.subdata(in: offset..<(offset + size))
    }
    mutating func string() throws -> String {
        guard let value = String(data: try bytes(), encoding: .utf8), !value.contains("\0") else { throw SFTPFailure.malformed }; return value
    }
    mutating func attributes() throws -> (RemoteFileKind, UInt64?, Date?) {
        let result = try attributesWithPermissions(); return (result.0, result.1, result.2)
    }
    mutating func attributesWithPermissions() throws -> (RemoteFileKind, UInt64?, Date?, UInt32) {
        let metadata = try fileAttributes()
        return (metadata.kind, metadata.size, metadata.modified, metadata.mode & 0o777)
    }
    mutating func fileAttributes() throws -> FileAttributes {
        let flags = try integer()
        guard flags & ~UInt32(0x8000000f) == 0 else { throw SFTPFailure.malformed }
        let size: UInt64? = flags & 1 != 0 ? try uint64() : nil
        if flags & 2 != 0 { _ = try integer(); _ = try integer() }
        let mode: UInt32 = flags & 4 != 0 ? try integer() : 0
        var modified: Date?
        if flags & 8 != 0 { _ = try integer(); modified = Date(timeIntervalSince1970: Double(try integer())) }
        if flags & 0x80000000 != 0 {
            let count = try integer(); guard count <= 1024 else { throw SFTPFailure.malformed }
            for _ in 0..<count { _ = try bytes(); _ = try bytes() }
        }
        let kind: RemoteFileKind
        switch mode & 0xf000 { case 0x4000: kind = .directory; case 0x8000: kind = .file; case 0xa000: kind = .symbolicLink; default: kind = .other }
        return FileAttributes(kind: kind, size: size, modified: modified, mode: mode)
    }
}

private final class SFTPChannel {
    let input: FileHandle, output: FileHandle
    let check: () throws -> Void
    let control: FileTransferControl?
    var nextID: UInt32 = 0
    private var extensions = Set<String>()
    init(input: FileHandle, output: FileHandle, check: @escaping () throws -> Void, control: FileTransferControl? = nil) {
        self.input = input; self.output = output; self.check = check; self.control = control
    }
    static func uint32(_ value: UInt32) -> Data { Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
    func write(type: UInt8, id: UInt32, fields: [SFTPField]) throws {
        var packet = Data([type]); packet.append(Self.uint32(id))
        for field in fields {
            switch field {
            case .integer(let value): packet.append(Self.uint32(value))
            case .string(let value):
                guard !value.contains("\0") else { throw SFTPFailure.malformed }
                let bytes = Data(value.utf8); guard bytes.count < 1048576 else { throw SFTPFailure.malformed }
                packet.append(Self.uint32(UInt32(bytes.count))); packet.append(bytes)
            case .bytes(let bytes): packet.append(Self.uint32(UInt32(bytes.count))); packet.append(bytes)
            }
        }
        var data = Self.uint32(UInt32(packet.count)); data.append(packet)
        try input.write(contentsOf: data)
    }
    func readExact(_ size: Int) throws -> Data {
        var result = Data()
        while result.count < size {
            guard let bytes = try output.read(upToCount: size - result.count), !bytes.isEmpty else { throw SFTPFailure.closed("") }
            result.append(bytes)
        }
        return result
    }
    func packet() throws -> (UInt8, SFTPReader) {
        var length = SFTPReader(data: try readExact(4)); let count = Int(try length.integer())
        guard count > 0 && count <= 4194304 else { throw SFTPFailure.malformed }
        var payload = SFTPReader(data: try readExact(count)); let type = try payload.byte()
        return (type, payload)
    }
    func initialize() throws {
        try check()
        try write(type: 1, id: 3, fields: [])
        var (type, payload) = try packet()
        guard type == 2, try payload.integer() == 3 else { throw SFTPFailure.unsupported }
        while payload.offset < payload.data.count {
            let name = try payload.string()
            if try payload.bytes() == Data("1".utf8) { extensions.insert(name) }
        }
    }
    func request(_ type: UInt8, fields: [SFTPField], checking: Bool = true) throws -> (UInt8, SFTPReader) {
        if checking { try check() }
        nextID += 1; try write(type: type, id: nextID, fields: fields)
        var (reply, payload) = try packet()
        guard try payload.integer() == nextID else { throw SFTPFailure.malformed }
        return (reply, payload)
    }
    func status(_ payload: inout SFTPReader) throws -> UInt32 {
        let code = try payload.integer(), message = try payload.string(); _ = try payload.string()
        if code != 0 && code != 1 { throw SFTPFailure.status(code, message) }; return code
    }
    func statusRequest(_ type: UInt8, fields: [SFTPField], checking: Bool = true) throws {
        var (reply, payload) = try request(type, fields: fields, checking: checking)
        guard reply == 101, try status(&payload) == 0 else { throw SFTPFailure.malformed }
    }
    func names(_ payload: inout SFTPReader) throws -> [(String, RemoteFileKind, UInt64?, Date?)] {
        let count = try payload.integer(); guard count <= 100000 else { throw SFTPFailure.tooManyEntries }
        var names: [(String, RemoteFileKind, UInt64?, Date?)] = []
        for _ in 0..<count {
            let name = try payload.string(); _ = try payload.bytes()
            let attrs = try payload.attributes(); names.append((name, attrs.0, attrs.1, attrs.2))
        }
        return names
    }
    func perform(_ operation: SFTPOperation) throws -> RemoteDirectory? {
        switch operation {
        case .uploadFile(let local, let remote): try uploadFile(local: local, remote: remote)
        case .stageUpload(let local, let remote, let directory): try uploadFile(local: local, remote: remote, handoff: directory)
        case .downloadFile(let remote, let local): try downloadFile(remote: remote, local: local)
        case .list(let path): return try list(path)
        case .makeDirectory(let path): try statusRequest(14, fields: [.string(path), .integer(0)])
        case .makeFile(let path):
            let handle = try openFile(path, flags: 0x2a)
            try statusRequest(4, fields: [.bytes(handle)])
        case .copyFile(let source, let target): try copyFile(source, target)
        case .rename(let from, let to): try statusRequest(18, fields: [.string(from), .string(to)])
        case .removeFile(let path): try statusRequest(13, fields: [.string(path)])
        case .removeDirectory(let path): try statusRequest(15, fields: [.string(path)])
        case .removeTree(let path):
            try FilePaths.validateDeletion(path)
            var pending: [(String, Bool, Int)] = [(path, false, 0)]
            var visited = 0
            while let (current, removing, depth) = pending.popLast() {
                visited += 1
                guard visited <= 200000, depth <= 256 else { throw SFTPFailure.tooManyEntries }
                if removing { try statusRequest(15, fields: [.string(current)]); continue }
                var (type, attributes) = try request(7, fields: [.string(current)]) // LSTAT: never follow a link.
                if type == 101 { _ = try status(&attributes); throw SFTPFailure.malformed }
                guard type == 105 else { throw SFTPFailure.malformed }
                if try attributes.attributes().0 != .directory { try statusRequest(13, fields: [.string(current)]); continue }
                let directory = try list(current)
                guard directory.path == current else { throw SFTPFailure.malformed }
                pending.append((current, true, depth))
                pending.append(contentsOf: directory.entries.map { ($0.path, false, depth + 1) })
            }
        case .batch(let operations):
            var result: RemoteDirectory?
            for operation in operations { result = try perform(operation) ?? result }
            return result
        }
        return nil
    }
    private func entryAttributes(_ path: String) throws -> SFTPReader.FileAttributes? {
        var (type, attributes) = try request(7, fields: [.string(path)])
        if type == 101 {
            do { _ = try status(&attributes); throw SFTPFailure.malformed }
            catch SFTPFailure.status(let code, _) where code == 2 { return nil }
        }
        guard type == 105 else { throw SFTPFailure.malformed }
        return try attributes.fileAttributes()
    }
    private func uploadFile(local: String, remote: String, handoff: String? = nil) throws {
        if handoff == nil, let existing = try entryAttributes(remote) {
            throw existing.kind == .file ? RemoteUpload.destinationExists(remote) : RemoteUpload.invalidTarget(remote)
        }
        let url = URL(fileURLWithPath: local)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size >= 0 else {
            throw SSHError.invalid("请选择普通文件；目录和符号链接不自动跟随")
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let permissions = (try FileManager.default.attributesOfItem(atPath: local)[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o600
        let directory = try handoff ?? RemoteUpload.stagingDirectory(for: remote)
        let staging = directory + "/file"
        if handoff == nil {
            try statusRequest(14, fields: [.string(directory), .integer(4), .integer(0o700)])
        }
        var handle: Data?
        var completed = false
        defer {
            // A cancelled transfer can still send cleanup requests at the next
            // protocol boundary. The transport bounds this grace period.
            if let handle { try? statusRequest(4, fields: [.bytes(handle)], checking: false) }
            if !completed { try? statusRequest(13, fields: [.string(staging)], checking: false) }
            if !completed || handoff == nil { try? statusRequest(15, fields: [.string(directory)], checking: false) }
        }
        guard let directoryMetadata = try entryAttributes(directory),
              directoryMetadata.kind == .directory, directoryMetadata.mode & 0o077 == 0 else {
            throw RemoteUpload.unsupported
        }
        let output = try openFile(staging, flags: 0x2a, permissions: handoff == nil ? permissions & 0o777 : 0o600)
        handle = output
        control?.beginFile(remote, size: UInt64(size))
        var offset: UInt64 = 0
        while offset < UInt64(size) {
            try check()
            guard let bytes = try input.read(upToCount: Int(min(UInt64(size) - offset, 32768))), !bytes.isEmpty else {
                throw RemoteUpload.sourceChanged(local)
            }
            try statusRequest(6, fields: [.bytes(output), .integer(UInt32(offset >> 32)), .integer(UInt32(truncatingIfNeeded: offset)), .bytes(bytes)])
            offset += UInt64(bytes.count); control?.advance(bytes.count)
        }
        if let extra = try input.read(upToCount: 1), !extra.isEmpty { throw RemoteUpload.sourceChanged(local) }
        if extensions.contains("fsync@openssh.com") {
            try statusRequest(200, fields: [.string("fsync@openssh.com"), .bytes(output)])
        }
        try statusRequest(4, fields: [.bytes(output)])
        handle = nil
        try check()
        if handoff == nil {
            // SFTP v3 RENAME rejects an existing destination. Do not use the
            // overwrite extension for a path that was absent.
            guard try entryAttributes(remote) == nil else { throw RemoteUpload.destinationChanged(remote) }
            try statusRequest(18, fields: [.string(staging), .string(remote)])
        }
        completed = true
        control?.finish()
    }
    private func downloadFile(remote: String, local: String) throws {
        let url = URL(fileURLWithPath: local)
        guard let metadata = try entryAttributes(remote), metadata.kind == .file else {
            throw SSHError.invalid("请选择普通文件；目录和符号链接不自动跟随")
        }
        let handle = try openFile(remote, flags: 1)
        var remoteClosed = false
        defer { if !remoteClosed { try? statusRequest(4, fields: [.bytes(handle)]) } }
        guard FileManager.default.createFile(atPath: local, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw SSHError.invalid("无法打开文件")
        }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        control?.beginFile(remote, size: metadata.size ?? 0)
        var offset: UInt64 = 0
        while true {
            var (type, reply) = try request(5, fields: [.bytes(handle), .integer(UInt32(offset >> 32)), .integer(UInt32(truncatingIfNeeded: offset)), .integer(32768)])
            if type == 101 { if try status(&reply) == 1 { break }; throw SFTPFailure.malformed }
            guard type == 103 else { throw SFTPFailure.malformed }
            let bytes = try reply.bytes(); guard !bytes.isEmpty, bytes.count <= 32768 else { throw SFTPFailure.malformed }
            try file.write(contentsOf: bytes); offset += UInt64(bytes.count); control?.advance(bytes.count)
        }
        try statusRequest(4, fields: [.bytes(handle)])
        remoteClosed = true
        try file.synchronize()
        if control?.preserveFilePermissions != false {
            try FileManager.default.setAttributes([.posixPermissions: metadata.mode & 0o777], ofItemAtPath: local)
        }
        control?.finish()
    }
    func inspectFile(_ path: String) throws -> EditorFileInspection {
        var (type, attributes) = try request(7, fields: [.string(path)])
        if type == 101 { _ = try status(&attributes); throw SFTPFailure.malformed }
        guard type == 105, try attributes.attributes().0 == .file else { throw SSHError.invalid("请选择普通文件；目录和符号链接不自动跟随") }
        let handle = try openFile(path, flags: 1)
        defer { try? statusRequest(4, fields: [.bytes(handle)]) }
        var (kind, metadata) = try request(8, fields: [.bytes(handle)])
        if kind == 101 { _ = try status(&metadata); throw SFTPFailure.malformed }
        guard kind == 105 else { throw SFTPFailure.malformed }
        let info = try metadata.attributes()
        guard info.0 == .file else { throw SSHError.invalid("请选择普通文件；目录和符号链接不自动跟随") }
        var header = Data()
        while header.count < EditorFileInspection.headerLimit {
            let remaining = EditorFileInspection.headerLimit - header.count
            var (reply, payload) = try request(5, fields: [.bytes(handle), .integer(0), .integer(UInt32(header.count)), .integer(UInt32(remaining))])
            if reply == 101 { if try status(&payload) == 1 { break }; throw SFTPFailure.malformed }
            guard reply == 103 else { throw SFTPFailure.malformed }
            let block = try payload.bytes()
            guard !block.isEmpty, block.count <= remaining else { throw SFTPFailure.malformed }
            header.append(block)
        }
        return EditorFileInspection(size: info.1, header: header)
    }
    private func openFile(_ path: String, flags: UInt32, permissions: UInt32 = 0o600) throws -> Data {
        var (type, payload) = try request(3, fields: [.string(path), .integer(flags), .integer(4), .integer(permissions)])
        if type == 101 { _ = try status(&payload); throw SFTPFailure.malformed }
        guard type == 102 else { throw SFTPFailure.malformed }
        return try payload.bytes()
    }
    private func copyFile(_ source: String, _ target: String) throws {
        var (type, attributes) = try request(7, fields: [.string(source)])
        if type == 101 { _ = try status(&attributes); throw SFTPFailure.malformed }
        guard type == 105 else { throw SFTPFailure.malformed }
        let metadata = try attributes.attributes()
        guard metadata.0 == .file else { throw SSHError.invalid("请选择普通文件；目录和符号链接不自动跟随") }
        control?.beginFile(source, size: metadata.1 ?? 0)
        let input = try openFile(source, flags: 1)
        defer { try? statusRequest(4, fields: [.bytes(input)]) }
        let temporary = try FilePaths.child(".termvia-copy-" + UUID().uuidString, in: (target as NSString).deletingLastPathComponent)
        let output = try openFile(temporary, flags: 0x2a)
        var outputOpen = true, committed = false
        defer {
            if outputOpen { try? statusRequest(4, fields: [.bytes(output)]) }
            if !committed { try? statusRequest(13, fields: [.string(temporary)]) }
        }
        var offset: UInt64 = 0
        while true {
            var (type, payload) = try request(5, fields: [.bytes(input), .integer(UInt32(offset >> 32)), .integer(UInt32(truncatingIfNeeded: offset)), .integer(32768)])
            if type == 101 {
                if try status(&payload) == 1 {
                    try statusRequest(4, fields: [.bytes(output)]); outputOpen = false
                    try statusRequest(18, fields: [.string(temporary), .string(target)]); committed = true
                    return
                }
                throw SFTPFailure.malformed
            }
            guard type == 103 else { throw SFTPFailure.malformed }
            let bytes = try payload.bytes(); guard !bytes.isEmpty, bytes.count <= 32768 else { throw SFTPFailure.malformed }
            try statusRequest(6, fields: [.bytes(output), .integer(UInt32(offset >> 32)), .integer(UInt32(truncatingIfNeeded: offset)), .bytes(bytes)])
            offset += UInt64(bytes.count); control?.advance(bytes.count)
        }
    }
    private func followedMetadata(_ path: String) throws -> (RemoteFileKind, UInt64?, Date?) {
        var (type, payload) = try request(17, fields: [.string(path)]) // STAT follows links.
        if type == 101 { _ = try status(&payload); throw SFTPFailure.malformed }
        guard type == 105 else { throw SFTPFailure.malformed }
        return try payload.attributes()
    }
    func resolveEntry(_ path: String) throws -> RemoteEntry {
        var (type, payload) = try request(16, fields: [.string(path)])
        if type == 101 { _ = try status(&payload); throw SFTPFailure.malformed }
        guard type == 104 else { throw SFTPFailure.malformed }
        let canonical = try names(&payload)
        guard canonical.count == 1, canonical[0].0.hasPrefix("/") else { throw SFTPFailure.malformed }
        let target = canonical[0].0, metadata = try followedMetadata(target)
        guard metadata.0 == .file || metadata.0 == .directory else { throw SSHError.invalid("无法打开文件") }
        return RemoteEntry(name: (target as NSString).lastPathComponent, path: target, kind: metadata.0, size: metadata.1, modified: metadata.2)
    }
    private func annotateLinks(_ entries: [RemoteEntry]) throws -> [RemoteEntry] {
        try entries.map { entry in
            guard entry.kind == .symbolicLink else { return entry }
            do {
                let metadata = try followedMetadata(entry.path)
                return RemoteEntry(name: entry.name, path: entry.path, kind: .symbolicLink, size: metadata.1, modified: metadata.2, linkTargetKind: metadata.0)
            } catch SFTPFailure.status { return entry } // Broken/inaccessible links remain visible.
        }
    }
    func list(_ path: String) throws -> RemoteDirectory {
        var (type, payload) = try request(16, fields: [.string(path)])
        if type == 101 { _ = try status(&payload); throw SFTPFailure.malformed }
        guard type == 104 else { throw SFTPFailure.malformed }
        let canonical = try names(&payload)
        guard canonical.count == 1, canonical[0].0.hasPrefix("/") else { throw SFTPFailure.malformed }
        let directory = canonical[0].0
        (type, payload) = try request(11, fields: [.string(directory)])
        if type == 101 { _ = try status(&payload); throw SFTPFailure.malformed }
        guard type == 102 else { throw SFTPFailure.malformed }
        let handle = try payload.bytes(); defer { try? statusRequest(4, fields: [.bytes(handle)]) }
        var entries: [RemoteEntry] = [], paths = Set<Data>()
        for _ in 0..<100000 {
            (type, payload) = try request(12, fields: [.bytes(handle)])
            if type == 101 { if try status(&payload) == 1 { return RemoteDirectory(path: directory, entries: try annotateLinks(entries)) }; throw SFTPFailure.malformed }
            guard type == 104 else { throw SFTPFailure.malformed }
            let page = try names(&payload); guard !page.isEmpty else { throw SFTPFailure.malformed }
            for (name, kind, size, date) in page where name != "." && name != ".." {
                let path = try FilePaths.child(name, in: directory)
                guard paths.insert(Data(path.utf8)).inserted else { throw SFTPFailure.malformed }
                entries.append(RemoteEntry(name: name, path: path, kind: kind, size: size, modified: date))
                guard entries.count <= 100000 else { throw SFTPFailure.tooManyEntries }
            }
        }
        throw SFTPFailure.tooManyEntries
    }
}
