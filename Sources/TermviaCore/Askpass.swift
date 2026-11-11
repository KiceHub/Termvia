import Foundation
import Darwin

public struct AskpassRequest: Codable, Sendable {
    public let token: String
    public let prompt: String
    public let hint: String
    public var isHostKeyConfirmation: Bool {
        prompt.contains("Are you sure you want to continue connecting") && prompt.contains("key fingerprint is") && prompt.contains("SHA256:")
    }
    public init(token: String, prompt: String, hint: String = "") { self.token = token; self.prompt = prompt; self.hint = hint }
}
private struct AskpassResponse: Codable { let value: String? }
private enum SocketWire {
    static func address<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = path.utf8CString.map { UInt8(bitPattern: $0) }
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SSHError.invalid("认证通道路径过长") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    }
    static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0, size = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 ? pid : nil
    }
    static func isDescendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
        var current = pid
        for _ in 0..<32 {
            if current == ancestor { return true }
            guard current > 1 else { return false }
            var info = proc_bsdinfo()
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return false }
            current = pid_t(info.pbi_ppid)
        }
        return false
    }
    static func configure(_ fd: Int32) {
        var flag: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout.size(ofValue: flag)))
        var timeout = timeval(tv_sec: 300, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    static func write<T: Encodable>(_ value: T, to fd: Int32) throws {
        var data = try JSONEncoder().encode(value); data.append(10)
        guard data.count <= 65536 else { throw SSHError.invalid("认证请求过长") }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SSHError.invalid("认证通道已关闭") }
                offset += count
            }
        }
    }
    static func read<T: Decodable>(_ type: T.Type, from fd: Int32) throws -> T {
        var data = Data(), bytes = [UInt8](repeating: 0, count: 1024)
        while data.count < 65536 {
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw SSHError.invalid("认证通道已关闭") }
            data.append(contentsOf: bytes.prefix(count))
            if let end = data.firstIndex(of: 10) { return try JSONDecoder().decode(type, from: data.prefix(upTo: end)) }
        }
        throw SSHError.invalid("认证请求过长")
    }
}

/// One short-lived, user-private channel per SSH process. No secret is placed in
/// its environment or arguments; only an unguessable channel token is inherited.
public final class AskpassServer: @unchecked Sendable {
    public typealias Handler = @Sendable (AskpassRequest) async -> String?
    public let token = UUID().uuidString + UUID().uuidString
    public let socketURL: URL
    private let directory: URL
    private let ownerPID = getpid()
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var listenerSource: DispatchSourceRead?
    private var clients = Set<Int32>()
    private var handler: Handler?
    public init(handler: @escaping Handler) throws {
        directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("termvia-auth-" + UUID().uuidString)
        socketURL = directory.appendingPathComponent("s")
        self.handler = handler
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { try? FileManager.default.removeItem(at: directory); throw SSHError.invalid("无法创建认证通道") }
        SocketWire.configure(fd)
        do {
            guard try SocketWire.address(socketURL.path, { Darwin.bind(fd, $0, $1) }) == 0,
                  chmod(socketURL.path, 0o600) == 0, Darwin.listen(fd, 4) == 0,
                  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw SSHError.invalid("无法创建认证通道") }
        } catch { Darwin.close(fd); try? FileManager.default.removeItem(at: directory); throw error }
        listener = fd
        // shutdown(listening Unix socket) returns ENOTCONN on macOS and does
        // not wake a blocking accept. A read source needs no parked worker;
        // its cancellation handler owns the descriptor's final close.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in self?.acceptPending(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        listenerSource = source; source.resume()
    }
    private func acceptPending(_ listenerFD: Int32) {
        while true {
            lock.lock(); let open = listener == listenerFD; lock.unlock()
            guard open else { return }
            let client = Darwin.accept(listenerFD, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            // BSD may inherit O_NONBLOCK from the listener. Client reads are
            // performed by a bounded worker and retain their socket timeout.
            guard fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK) == 0 else { Darwin.close(client); continue }
            accept(client)
        }
    }
    private func accept(_ fd: Int32) {
        SocketWire.configure(fd)
        lock.lock()
        guard listener >= 0, clients.count < 16, let handler else { lock.unlock(); Darwin.close(fd); return }
        clients.insert(fd); lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid(),
                      let peer = SocketWire.peerPID(fd), SocketWire.isDescendant(peer, of: self.ownerPID) else { throw SSHError.invalid("认证通道拒绝访问") }
                let request = try SocketWire.read(AskpassRequest.self, from: fd)
                guard request.token == self.token, request.prompt.utf8.count <= 32768 else { throw SSHError.invalid("认证通道拒绝访问") }
                Task { [self] in
                    let value = await handler(request)
                    try? SocketWire.write(AskpassResponse(value: value), to: fd)
                    self.finish(fd)
                }
            } catch { self.finish(fd) }
        }
    }
    private func finish(_ fd: Int32) {
        lock.lock(); let owned = clients.remove(fd) != nil; lock.unlock()
        if owned { Darwin.close(fd) }
    }
    public func environment(helper: URL) -> [String: String] {
        ["SSH_ASKPASS": helper.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": "termvia:0",
         "TERMVIA_AUTH_SOCKET": socketURL.path, "TERMVIA_AUTH_TOKEN": token, "LC_ALL": "C"]
    }
    public func close() {
        lock.lock()
        let source = listenerSource; listenerSource = nil; listener = -1; handler = nil
        // The dispatch source closes after its event handler has returned,
        // so another descriptor cannot be reused underneath accept.
        for client in clients { _ = Darwin.shutdown(client, SHUT_RDWR) }
        lock.unlock()
        source?.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { close() }
}

public enum AskpassClient {
    public static func response(prompt: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String? {
        guard let path = environment["TERMVIA_AUTH_SOCKET"], let token = environment["TERMVIA_AUTH_TOKEN"], !token.isEmpty else { return nil }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        SocketWire.configure(fd)
        guard try SocketWire.address(path, { Darwin.connect(fd, $0, $1) }) == 0 else { return nil }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid(),
              let peer = SocketWire.peerPID(fd), SocketWire.isDescendant(getpid(), of: peer) else { return nil }
        try SocketWire.write(AskpassRequest(token: token, prompt: prompt, hint: environment["SSH_ASKPASS_PROMPT"] ?? ""), to: fd)
        let response = try SocketWire.read(AskpassResponse.self, from: fd).value
        if let response { try validateLoginSecret(response) }
        return response
    }
}
