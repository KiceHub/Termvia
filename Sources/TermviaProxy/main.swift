import Foundation
import Darwin
import TermviaCore

// ProxyCommand's stdout is a binary SSH stream. All failures go to stderr.
struct Configuration: Decodable { let proxy: SSHProxy; let password: String; let target: String; let port: Int }
func fail() -> Never { FileHandle.standardError.write(Data("Termvia: proxy connection failed\n".utf8)); exit(1) }
func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
    try bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw SSHError.invalid("proxy write") }; offset += n
        }
    }
}
func readExact(_ fd: Int32, _ count: Int) throws -> [UInt8] {
    var result = [UInt8](repeating: 0, count: count), offset = 0
    while offset < count {
        let n = result.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw SSHError.invalid("proxy read") }; offset += n
    }
    return result
}
signal(SIGPIPE, SIG_IGN)
guard CommandLine.arguments.count == 2 else { fail() }
do {
    let c = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    try c.proxy.validate()
    try SSHHost(name: "proxy target", address: c.target, user: "proxy", port: c.port).validate()
    guard (1...65535).contains(c.port), c.target.utf8.count <= 255, c.password.utf8.count <= 255 else { fail() }
    var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP
    var addresses: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(c.proxy.address, String(c.proxy.port), &hints, &addresses) == 0 else { fail() }
    defer { if let addresses { freeaddrinfo(addresses) } }
    var cursor = addresses, fd: Int32 = -1
    while let address = cursor {
        let a = address.pointee, candidate = socket(a.ai_family, a.ai_socktype, a.ai_protocol)
        if candidate >= 0 {
            var timeout = timeval(tv_sec: 15, tv_usec: 0)
            setsockopt(candidate, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(candidate, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            // Bound connect as well as handshake time, including an unreachable proxy.
            _ = fcntl(candidate, F_SETFL, O_NONBLOCK)
            let connected = connect(candidate, a.ai_addr, a.ai_addrlen)
            var pollfd = pollfd(fd: candidate, events: Int16(POLLOUT), revents: 0)
            if connected == 0 || (errno == EINPROGRESS && poll(&pollfd, 1, 15000) > 0) {
                var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(candidate, SOL_SOCKET, SO_ERROR, &error, &size)
                if error == 0 { _ = fcntl(candidate, F_SETFL, 0); fd = candidate; break }
            }
            close(candidate)
        }
        cursor = a.ai_next
    }
    guard fd >= 0 else { fail() }; defer { close(fd) }
    if c.proxy.kind == .socks5 {
        let authenticated = !c.proxy.username.isEmpty
        try writeAll(fd, authenticated ? [5, 1, 2] : [5, 1, 0])
        let method = try readExact(fd, 2)
        guard method == [5, authenticated ? 2 : 0] else { fail() }
        if authenticated {
            let user = Array(c.proxy.username.utf8), password = Array(c.password.utf8)
            try writeAll(fd, [1, UInt8(user.count)] + user + [UInt8(password.count)] + password)
            guard try readExact(fd, 2) == [1, 0] else { fail() }
        }
        var ipv4 = in_addr(), ipv6 = in6_addr()
        let address: [UInt8]
        if c.target.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            address = [1] + withUnsafeBytes(of: &ipv4) { Array($0) }
        } else if c.target.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            address = [4] + withUnsafeBytes(of: &ipv6) { Array($0) }
        } else {
            let target = Array(c.target.utf8); address = [3, UInt8(target.count)] + target
        }
        try writeAll(fd, [5, 1, 0] + address + [UInt8(c.port >> 8), UInt8(c.port & 255)])
        let reply = try readExact(fd, 4)
        guard reply[0] == 5, reply[1] == 0, reply[2] == 0 else { fail() }
        switch reply[3] {
        case 1: _ = try readExact(fd, 4)
        case 4: _ = try readExact(fd, 16)
        case 3: let count = Int(try readExact(fd, 1)[0]); _ = try readExact(fd, count)
        default: fail()
        }
        _ = try readExact(fd, 2)
    } else {
        let target = (c.target.contains(":") ? "[\(c.target)]" : c.target) + ":\(c.port)"
        var header = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n"
        if !c.proxy.username.isEmpty { header += "Proxy-Authorization: Basic " + Data((c.proxy.username + ":" + c.password).utf8).base64EncodedString() + "\r\n" }
        try writeAll(fd, Array((header + "\r\n").utf8))
        var bytes: [UInt8] = []
        while !bytes.suffix(4).elementsEqual([13, 10, 13, 10]) { guard bytes.count < 16384 else { fail() }; bytes += try readExact(fd, 1) }
        let status = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")[0].split(separator: " ")
        guard status.count >= 2, status[0].hasPrefix("HTTP/"), status[1] == "200" else { fail() }
    }
    var timeout = timeval(tv_sec: 0, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var input = true, output = true, buffer = [UInt8](repeating: 0, count: 65536)
    while output {
        var descriptors = [pollfd(fd: input ? STDIN_FILENO : -1, events: Int16(POLLIN), revents: 0), pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
        if poll(&descriptors, 2, -1) < 0 { if errno == EINTR { continue }; fail() }
        for index in 0...1 where descriptors[index].revents != 0 {
            let n = Darwin.read(index == 0 ? STDIN_FILENO : fd, &buffer, buffer.count)
            if n > 0 { try writeAll(index == 0 ? fd : STDOUT_FILENO, Array(buffer.prefix(n))) }
            else if n == 0 { if index == 0 { input = false; shutdown(fd, SHUT_WR) } else { output = false } }
            else if errno != EINTR { fail() }
        }
    }
} catch { fail() }
