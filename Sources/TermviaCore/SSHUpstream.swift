import Foundation
import Darwin

/// Exactly one edge per host. Walking these edges produces a jump chain.
public enum SSHUpstream: Codable, Equatable, Sendable {
    case host(UUID), proxy(UUID)
}
public struct SSHProxy: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case socks5, http, wireguard }
    public var id = UUID()
    public var name = ""
    public var kind = Kind.socks5
    public var address = "127.0.0.1"
    public var port = 1080
    public var username = ""
    public struct WireGuard: Codable, Equatable, Sendable {
        public var peerPublicKey = ""
        public var localIP = ""
        public var mtu = 1420
        public init() {}
    }
    public var wireGuard: WireGuard? = nil
    public init() {}
    public func validate() throws {
        if kind == .wireguard {
            let address = wireGuard?.localIP.split(separator: "/").first.map(String.init) ?? ""
            var a = in_addr(), b = in6_addr()
            let v4 = address.withCString { inet_pton(AF_INET, $0, &a) } == 1
            let v6 = address.withCString { inet_pton(AF_INET6, $0, &b) } == 1
            let parts = wireGuard?.localIP.split(separator: "/", omittingEmptySubsequences: false) ?? []
            let prefixValid = parts.count == 1 || (parts.count == 2 && Int(parts[1]).map { (0...(v4 ? 32 : 128)).contains($0) } == true)
            guard (v4 || v6) && prefixValid else { throw SSHError.invalid("请检查 WireGuard 公钥、本机 IP 和 MTU") }
            guard let wireGuard, Data(base64Encoded: wireGuard.peerPublicKey)?.count == 32,
                  !wireGuard.localIP.isEmpty, (576...9000).contains(wireGuard.mtu) else { throw SSHError.invalid("请检查 WireGuard 公钥、本机 IP 和 MTU") }
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:")
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !address.isEmpty,
              address.unicodeScalars.allSatisfy(allowed.contains), (1...65535).contains(port),
              username.utf8.count <= 255, !username.contains(":"), username.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw SSHError.invalid("请检查代理名称、地址、端口和用户名")
        }
    }
}
public enum SSHRoute {
    public static func chain(for host: SSHHost, hosts: [SSHHost], proxies: [SSHProxy]) throws -> [SSHHost] {
        var result: [SSHHost] = [], seen = Set<UUID>(), current = host
        while true {
            guard seen.insert(current.id).inserted else { throw SSHError.invalid("跳板机链存在循环") }
            try current.validate(); result.append(current)
            switch current.upstream {
            case .host(let id):
                guard let next = hosts.first(where: { $0.id == id }) else { throw SSHError.invalid("找不到上游跳板机") }
                current = next
            case .proxy(let id):
                guard let proxy = proxies.first(where: { $0.id == id }) else { throw SSHError.invalid("找不到代理服务器") }
                try proxy.validate(); return result.reversed()
            case nil: return result.reversed()
            }
        }
    }
    public static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func terminalPaths(_ paths: [String]) throws -> String {
        guard paths.allSatisfy({ $0.hasPrefix("/") && $0.rangeOfCharacter(from: .controlCharacters) == nil }) else {
            throw SSHError.invalid("路径包含不支持的控制字符")
        }
        return paths.map(shellQuote).joined(separator: " ")
    }
}
