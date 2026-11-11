import Foundation

public struct SSHHost: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var address: String
    public var user: String
    public var port: Int
    public var identity: String
    public var customIcon: String? = nil
    public var detectedSystem: String? = nil
    public var detectedSystemVersion: Int? = nil
    public var group: String? = nil
    public var authentication: SSHAuthentication? = nil
    public var credentialID: UUID? = nil
    public var fileProtocol: SSHCommands.FileProtocol? = nil
    public init(name: String, address: String, user: String, port: Int = 22, identity: String = "") {
        self.name = name; self.address = address; self.user = user; self.port = port; self.identity = identity
    }
    public func validate() throws {
        if authentication == .privateKey || authentication == .keyAndPassword, identity.isEmpty { throw SSHError.invalid("请选择私钥文件") }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:%")
        guard !address.isEmpty, !address.hasPrefix("-"), address.unicodeScalars.allSatisfy(allowed.contains),
              !user.isEmpty, !user.hasPrefix("-"), user.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
              (1...65535).contains(port), !identity.contains("\n"), !identity.contains("\r"), !identity.contains("\0"), !identity.contains("${") else {
            throw SSHError.invalid("请检查主机地址、用户名、端口和密钥路径")
        }
    }
}

public enum SSHError: LocalizedError {
    case invalid(String), failed(Int32, String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return T(message)
        case .failed(let code, let message): return T("退出码 %d：%@", code, message) }
    }
}

public struct Invocation: Sendable {
    public var executable: String
    public var arguments: [String]
    public var input: Data? = nil
    public var environment: [String: String] = [:]
    public init(executable: String, arguments: [String], input: Data? = nil) {
        self.executable = executable; self.arguments = arguments; self.input = input
    }
}

public struct SSHCommands: Sendable {
    public let knownHosts: String
    public let useAskpass: Bool
    public let suppressWarnings: Bool
    public let keepAliveInterval: Int
    public init(knownHosts: String, useAskpass: Bool = false, suppressWarnings: Bool = true, keepAliveInterval: Int = 0) {
        self.knownHosts = knownHosts; self.useAskpass = useAskpass; self.suppressWarnings = suppressWarnings
        self.keepAliveInterval = min(300, max(0, keepAliveInterval))
    }
    private func options(_ host: SSHHost, interactive: Bool) throws -> [String] {
        try host.validate()
        let trustPath = knownHosts.replacingOccurrences(of: "%", with: "%%").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var args = ["-F", "/dev/null", "-o", "UserKnownHostsFile=\"\(trustPath)\"",
                    "-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=\(interactive ? "ask" : "yes")",
                    "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=\(keepAliveInterval)", "-o", "ServerAliveCountMax=3", "-o", "TCPKeepAlive=no",
                    "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no"]
        if suppressWarnings { args += ["-o", "WarnWeakCrypto=no", "-o", "LogLevel=ERROR"] }
        if !interactive { args += ["-o", "BatchMode=\(useAskpass ? "no" : "yes")"] }
        args += ["-o", "NumberOfPasswordPrompts=3"]
        switch host.authentication ?? .automatic {
        case .automatic: break
        case .password:
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no", "-o", "KbdInteractiveAuthentication=yes"]
        case .keyAndPassword:
            args += ["-o", "PreferredAuthentications=publickey,password,keyboard-interactive", "-o", "IdentitiesOnly=yes", "-o", "PasswordAuthentication=yes", "-o", "KbdInteractiveAuthentication=yes"]
        case .privateKey:
            args += ["-o", "PreferredAuthentications=publickey", "-o", "IdentitiesOnly=yes", "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no"]
        }
        if !host.identity.isEmpty {
            // -i checks existence before OpenSSH expands percent tokens. Use
            // its configuration option so literal % paths need no dummy file.
            let path = NSString(string: host.identity).expandingTildeInPath.replacingOccurrences(of: "%", with: "%%").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            args += ["-o", "IdentityFile=\"\(path)\""]
        }
        return args
    }
    private func destination(_ host: SSHHost) -> String {
        "\(host.user)@\(host.address.contains(":") ? "[\(host.address)]" : host.address)"
    }
    public func terminal(_ host: SSHHost) throws -> Invocation {
        Invocation(executable: "/usr/bin/ssh", arguments: try options(host, interactive: true) + ["-tt", "-p", String(host.port), "--", destination(host)])
    }
    public func sftpSubsystem(_ host: SSHHost) throws -> Invocation {
        Invocation(executable: "/usr/bin/ssh", arguments: try options(host, interactive: false) + ["-T", "-s", "-p", String(host.port), "--", destination(host), "sftp"])
    }
    public func connectionCheck(_ host: SSHHost, controlPath: String) throws -> Invocation {
        Invocation(executable: "/usr/bin/ssh", arguments: try options(host, interactive: true) + ["-M", "-N", "-S", controlPath, "-p", String(host.port), "--", destination(host)])
    }
    public func controlCheck(_ host: SSHHost, controlPath: String) throws -> Invocation {
        try host.validate()
        return Invocation(executable: "/usr/bin/ssh", arguments: ["-F", "/dev/null", "-S", controlPath, "-O", "check", "-p", String(host.port), "--", destination(host)])
    }
    public func execute(_ host: SSHHost, command: String) throws -> Invocation {
        Invocation(executable: "/usr/bin/ssh", arguments: try options(host, interactive: false) + ["-T", "-p", String(host.port), "--", destination(host), command])
    }
    public static func sftpQuote(_ path: String) throws -> String {
        guard !path.contains("\n"), !path.contains("\r"), !path.contains("\0") else { throw SSHError.invalid("路径包含不支持的控制字符") }
        return "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    public func listing(_ host: SSHHost, path: String) throws -> Invocation {
        Invocation(executable: "/usr/bin/sftp", arguments: try options(host, interactive: false) + ["-P", String(host.port), "-b", "-", "--", destination(host)], input: Data("ls -la \(try Self.sftpQuote(path))\n".utf8))
    }
    public enum FileProtocol: String, Codable, CaseIterable, Sendable { case sftp = "SFTP", scp = "SCP" }
    public func transfer(_ host: SSHHost, local: String, remote: String, upload: Bool, method: FileProtocol) throws -> Invocation {
        guard local.hasPrefix("/"), remote.hasPrefix("/"), !remote.contains("\n"), !remote.contains("\r"), !remote.contains("\0"), !local.contains("\n"), !local.contains("\r"), !local.contains("\0") else { throw SSHError.invalid("本地和远程路径必须是绝对路径") }
        if method == .sftp {
            let command = upload ? "put \(try Self.sftpQuote(local)) \(try Self.sftpQuote(remote))" : "get \(try Self.sftpQuote(remote)) \(try Self.sftpQuote(local))"
            return Invocation(executable: "/usr/bin/sftp", arguments: try options(host, interactive: false) + ["-P", String(host.port), "-b", "-", "--", destination(host)], input: Data((command + "\n").utf8))
        }
        // Legacy SCP sends the remote operand through a remote shell; quote it independently.
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
        let quotedRemote = remote.unicodeScalars.map { safe.contains($0) ? String($0) : "\\" + String($0) }.joined()
        let remoteOperand = destination(host) + ":" + quotedRemote
        return Invocation(executable: "/usr/bin/scp", arguments: try options(host, interactive: false) + ["-O", "-P", String(host.port), "--"] + (upload ? [local, remoteOperand] : [remoteOperand, local]))
    }
}

public enum AppPaths {
    public static func prepare(applicationSupport: URL? = nil) throws -> URL {
        let support = applicationSupport ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appendingPathComponent("Termvia", isDirectory: true)
        // Prefer the most recent (mistyped) name, then the original name.
        // Move the entire store, including trust records; never merge stores.
        if !FileManager.default.fileExists(atPath: root.path) {
            for name in ["Tremvia", "Termvian"] {
                let legacy = support.appendingPathComponent(name, isDirectory: true)
                if FileManager.default.fileExists(atPath: legacy.path) {
                    try FileManager.default.moveItem(at: legacy, to: root)
                    break
                }
            }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }
}
