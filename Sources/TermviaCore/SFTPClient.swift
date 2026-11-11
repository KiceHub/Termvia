import Foundation
import Darwin

public enum RemoteFileKind: String, Codable, Sendable { case file, directory, symbolicLink, other }
public struct RemoteEntry: Identifiable, Equatable, Codable, Sendable {
    public let name: String
    public let path: String
    public let kind: RemoteFileKind
    public let size: UInt64?
    public let modified: Date?
    public init(name: String, path: String, kind: RemoteFileKind, size: UInt64? = nil, modified: Date? = nil) {
        self.name = name; self.path = path; self.kind = kind; self.size = size; self.modified = modified
    }
    public var id: String { Data(path.utf8).base64EncodedString() }
    public var sortSize: UInt64 { size ?? 0 }
    public var sortDate: Date { modified ?? .distantPast }
    public var displayName: String { name.replacingOccurrences(of: "\n", with: "↵").replacingOccurrences(of: "\r", with: "␍").replacingOccurrences(of: "\t", with: "⇥") }
}
public struct RemoteDirectory: Equatable, Codable, Sendable { public let path: String; public let entries: [RemoteEntry]; public init(path: String, entries: [RemoteEntry]) { self.path = path; self.entries = entries } }
public enum SFTPOperation: Sendable {
    case list(String), makeDirectory(String), makeFile(String), copyFile(String, String), rename(String, String), removeFile(String), removeDirectory(String), removeTree(String)
    indirect case batch([SFTPOperation])
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
    public init() {}
    public func cancel() { stop(timeout: false) }
    private func stop(timeout: Bool) {
        lock.lock(); cancelled = true; timedOut = timedOut || timeout; let child = process; lock.unlock()
        if let child { ChildProcess.stop(child) }
    }
    private func check() throws {
        lock.lock(); let cancel = cancelled, timeout = timedOut; lock.unlock()
        if timeout { throw SFTPFailure.timeout }; if cancel { throw CancellationError() }
    }
    public func perform(_ operation: SFTPOperation, invocation: Invocation) async throws -> RemoteDirectory? {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do { continuation.resume(returning: try run(operation, invocation: invocation)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { self.cancel() })
    }
    private func run(_ operation: SFTPOperation, invocation: Invocation) throws -> RemoteDirectory? {
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
        process = child; lock.unlock()
        let errorBuffer = ErrorBuffer()
        DispatchQueue.global().async {
            while let data = try? errors.fileHandleForReading.read(upToCount: 4096), !data.isEmpty { errorBuffer.append(data) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self, weak child] in
            guard let self, let child, child.isRunning else { return }; self.stop(timeout: true)
        }
        defer {
            try? input.fileHandleForWriting.close()
            ChildProcess.stop(child)
            child.waitUntilExit()
            try? output.fileHandleForReading.close()
            lock.lock(); process = nil; lock.unlock()
        }
        do {
            let channel = SFTPChannel(input: input.fileHandleForWriting, output: output.fileHandleForReading, check: check)
            try channel.initialize()
            let result = try channel.perform(operation)
            try check()
            return result
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
        return (kind, size, modified)
    }
}

private final class SFTPChannel {
    let input: FileHandle, output: FileHandle
    let check: () throws -> Void
    var nextID: UInt32 = 0
    init(input: FileHandle, output: FileHandle, check: @escaping () throws -> Void) { self.input = input; self.output = output; self.check = check }
    static func uint32(_ value: UInt32) -> Data { Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
    func write(type: UInt8, id: UInt32, fields: [SFTPField]) throws {
        try check(); var packet = Data([type]); packet.append(Self.uint32(id))
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
            try check()
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
        try write(type: 1, id: 3, fields: [])
        var (type, payload) = try packet()
        guard type == 2, try payload.integer() == 3 else { throw SFTPFailure.unsupported }
    }
    func request(_ type: UInt8, fields: [SFTPField]) throws -> (UInt8, SFTPReader) {
        nextID += 1; try write(type: type, id: nextID, fields: fields)
        var (reply, payload) = try packet()
        guard try payload.integer() == nextID else { throw SFTPFailure.malformed }
        return (reply, payload)
    }
    func status(_ payload: inout SFTPReader) throws -> UInt32 {
        let code = try payload.integer(), message = try payload.string(); _ = try payload.string()
        if code != 0 && code != 1 { throw SFTPFailure.status(code, message) }; return code
    }
    func statusRequest(_ type: UInt8, fields: [SFTPField]) throws {
        var (reply, payload) = try request(type, fields: fields)
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
    private func openFile(_ path: String, flags: UInt32) throws -> Data {
        var (type, payload) = try request(3, fields: [.string(path), .integer(flags), .integer(4), .integer(0o600)])
        if type == 101 { _ = try status(&payload); throw SFTPFailure.malformed }
        guard type == 102 else { throw SFTPFailure.malformed }
        return try payload.bytes()
    }
    private func copyFile(_ source: String, _ target: String) throws {
        var (type, attributes) = try request(7, fields: [.string(source)])
        if type == 101 { _ = try status(&attributes); throw SFTPFailure.malformed }
        guard type == 105, try attributes.attributes().0 == .file else { throw SSHError.invalid("请选择普通文件；目录和符号链接不自动跟随") }
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
            offset += UInt64(bytes.count)
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
            if type == 101 { if try status(&payload) == 1 { return RemoteDirectory(path: directory, entries: entries) }; throw SFTPFailure.malformed }
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
