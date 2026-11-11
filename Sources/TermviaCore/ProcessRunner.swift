import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
}

/// Single-use runner. Input and bounded output are pumped independently so
/// either pipe can exceed the kernel buffer without blocking the other.
public final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var started = false
    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true; let running = process; lock.unlock()
        if let running { ChildProcess.stop(running) }
    }
    public func run(_ invocation: Invocation, outputLimit: Int = 65536, onOutput: (@Sendable (Data) -> Void)? = nil) async throws -> CommandResult {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try self.perform(invocation, outputLimit: min(1048576, max(0, outputLimit)), onOutput: onOutput)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { self.cancel() })
    }
    private func perform(_ invocation: Invocation, outputLimit: Int, onOutput: (@Sendable (Data) -> Void)?) throws -> CommandResult {
        let child = Process(), output = Pipe(), input = Pipe()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        child.executableURL = URL(fileURLWithPath: invocation.executable); child.arguments = invocation.arguments
        child.standardOutput = output; child.standardError = output; child.standardInput = input
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"; environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment.merge(invocation.environment) { _, new in new }; child.environment = environment
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        guard !started else { lock.unlock(); throw SSHError.invalid("进程执行器不可重复使用") }
        started = true
        do { try child.run() } catch { lock.unlock(); throw error }
        process = child; lock.unlock()
        let writer = DispatchGroup(), failure = InputFailure()
        writer.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? input.fileHandleForWriting.close(); writer.leave() }
            do { if let bytes = invocation.input { try input.fileHandleForWriting.write(contentsOf: bytes) } }
            catch { failure.set(error); ChildProcess.stop(child) }
        }
        defer {
            ChildProcess.stop(child); child.waitUntilExit(); writer.wait()
            try? output.fileHandleForReading.close()
            lock.lock(); process = nil; lock.unlock()
        }
        var retained = Data()
        do {
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                if count == 0 { break }
                let bytes = Data(buffer.prefix(count))
                onOutput?(bytes)
                if outputLimit > 0 {
                    retained.append(bytes)
                    if retained.count > outputLimit { retained.removeFirst(retained.count - outputLimit) }
                }
            }
            child.waitUntilExit(); writer.wait()
            lock.lock(); let cancelled = self.cancelled; lock.unlock()
            if cancelled { throw CancellationError() }
            if child.terminationStatus == 0, let error = failure.error { throw error }
            return CommandResult(status: child.terminationStatus, output: String(decoding: retained, as: UTF8.self))
        } catch {
            lock.lock(); let cancelled = self.cancelled; lock.unlock()
            if cancelled { throw CancellationError() }
            throw error
        }
    }
    private final class InputFailure: @unchecked Sendable {
        private let lock = NSLock(); private var value: Error?
        func set(_ error: Error) { lock.lock(); value = error; lock.unlock() }
        var error: Error? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
