import Darwin
import Foundation
import os

public struct SSHAddressResolutionFailure: LocalizedError, Sendable {
    let address: String
    let code: Int32
    public var errorDescription: String? { T("无法解析主机地址 %@", address) }
    public var isRetryable: Bool { code == EAI_AGAIN || code == EAI_FAIL || code == EAI_SYSTEM }
}

public enum SSHAddressResolver {
    public static func addresses(for host: String) async throws -> [String] {
        try await performLookup { try lookup(host) }
    }

    static func performLookup(_ lookup: @escaping @Sendable () throws -> [String]) async throws -> [String] {
        let request = LookupRequest()
        let addresses = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard request.register(continuation) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // A cancelled tab stops waiting immediately, even if the system
                // resolver is still waiting for a nameserver to respond.
                DispatchQueue.global(qos: .userInitiated).async {
                    request.finish(Result(catching: lookup))
                }
            }
        } onCancel: {
            request.cancel()
        }
        try Task.checkCancellation()
        return addresses
    }

    private struct LookupRequest: Sendable {
        private struct State: Sendable {
            var continuation: CheckedContinuation<[String], Error>?
            var cancelled = false
        }
        private let state = OSAllocatedUnfairLock(initialState: State())

        func register(_ continuation: CheckedContinuation<[String], Error>) -> Bool {
            state.withLock {
                guard !$0.cancelled else { return false }
                $0.continuation = continuation
                return true
            }
        }
        func finish(_ result: Result<[String], Error>) {
            let continuation = state.withLock { state in
                let continuation = state.continuation
                state.continuation = nil
                return continuation
            }
            continuation?.resume(with: result)
        }
        func cancel() {
            state.withLock { $0.cancelled = true }
            finish(.failure(CancellationError()))
        }
    }

    private static func lookup(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var first: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &first)
        guard status == 0, let first else {
            throw SSHAddressResolutionFailure(address: host, code: status)
        }
        defer { freeaddrinfo(first) }
        var ipv6: [String] = [], ipv4: [String] = []
        var seen = Set<String>()
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let node = current {
            let info = node.pointee
            current = info.ai_next
            guard info.ai_family == AF_INET6 || info.ai_family == AF_INET else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(info.ai_addr, info.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard seen.insert(address).inserted else { continue }
            if info.ai_family == AF_INET6 { ipv6.append(address) } else { ipv4.append(address) }
        }
        guard !seen.isEmpty else { throw SSHAddressResolutionFailure(address: host, code: EAI_NONAME) }
        return ipv6 + ipv4
    }
}
