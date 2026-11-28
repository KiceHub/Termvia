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
    private var execution: Execution?
    private var cancelled = false
    private var started = false

    public init() {}

    public func cancel() {
        let running = lock.withLock {
            cancelled = true
            return execution
        }
        running?.cancel()
    }

    public func run(_ invocation: Invocation, outputLimit: Int = 65536, onOutput: (@Sendable (Data) -> Void)? = nil) async throws -> CommandResult {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                Execution(owner: self, invocation: invocation, outputLimit: min(1_048_576, max(0, outputLimit)),
                          onOutput: onOutput, continuation: continuation).start()
            }
        }, onCancel: { self.cancel() })
    }

    private func launch(_ execution: Execution) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            guard !started else { throw SSHError.invalid("进程执行器不可重复使用") }
            started = true
            try execution.child.run()
            self.execution = execution
        }
    }

    private func didFinish() -> Bool {
        lock.withLock {
            execution = nil
            return cancelled
        }
    }

    /// Only active I/O takes a dispatch worker. A master can sit idle for the
    /// life of its tab. All pipe state and completion are confined to this queue.
    private final class Execution: @unchecked Sendable {
        let child = Process()
        private let owner: ProcessRunner
        private let queue = DispatchQueue(label: "app.termvia.process", qos: .userInitiated)
        private let input = Pipe()
        private let output = Pipe()
        private let outputLimit: Int
        private let onOutput: (@Sendable (Data) -> Void)?
        private var continuation: CheckedContinuation<CommandResult, Error>?
        private var readSource: DispatchSourceRead?
        private var writeSource: DispatchSourceWrite?
        private var readBuffer = [UInt8](repeating: 0, count: 8192)
        private var retained = Data()
        private var inputData: Data?
        private var inputOffset = 0
        private var inputClosed = false
        private var outputClosed = false
        private var inputError: Error?
        private var outputError: Error?
        private var status: Int32?

        init(owner: ProcessRunner, invocation: Invocation, outputLimit: Int, onOutput: (@Sendable (Data) -> Void)?,
             continuation: CheckedContinuation<CommandResult, Error>) {
            self.owner = owner; self.outputLimit = outputLimit; self.onOutput = onOutput
            self.continuation = continuation; inputData = invocation.input
            child.executableURL = URL(fileURLWithPath: invocation.executable); child.arguments = invocation.arguments
            child.standardOutput = output; child.standardError = output; child.standardInput = input
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C"; environment["SSH_ASKPASS_REQUIRE"] = "never"
            environment.merge(invocation.environment) { _, new in new }; child.environment = environment
        }

        func start() {
            queue.async { [self] in
                do {
                    let readFD = self.output.fileHandleForReading.fileDescriptor
                    let writeFD = self.input.fileHandleForWriting.fileDescriptor
                    try Self.makeNonblocking(readFD)
                    try Self.makeNonblocking(writeFD)
                    guard fcntl(writeFD, F_SETNOSIGPIPE, 1) == 0 else { throw Self.systemError(errno) }
                    self.child.terminationHandler = { [weak self] child in
                        guard let self else { return }
                        let status = child.terminationStatus
                        self.queue.async { self.didTerminate(status) }
                    }
                    try self.owner.launch(self)
                    self.startReading(readFD)
                    if self.inputData?.isEmpty == false { self.startWriting(writeFD) }
                    else { self.closeInput() }
                } catch {
                    self.continuation?.resume(throwing: error)
                    self.continuation = nil
                }
            }
        }

        func cancel() {
            queue.async {
                ChildProcess.stop(self.child)
                self.stopReading()
                self.stopWriting()
            }
        }

        private func startReading(_ fd: Int32) {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in read(fd) }
            // The descriptor stays valid until the source has been unregistered.
            source.setCancelHandler { [self] in
                try? output.fileHandleForReading.close()
                outputClosed = true
                finishIfReady()
            }
            readSource = source
            source.resume()
        }

        private func read(_ fd: Int32) {
            for _ in 0..<8 {
                let count = readBuffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    let bytes = Data(readBuffer.prefix(count))
                    onOutput?(bytes)
                    if outputLimit > 0 {
                        retained.append(bytes)
                        if retained.count > outputLimit { retained.removeFirst(retained.count - outputLimit) }
                    }
                } else if count == 0 {
                    stopReading()
                    return
                } else {
                    let code = errno
                    if code == EINTR { continue }
                    if code == EAGAIN || code == EWOULDBLOCK { return }
                    outputError = Self.systemError(code)
                    ChildProcess.stop(child)
                    stopReading()
                    return
                }
            }
        }

        private func startWriting(_ fd: Int32) {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in write(fd) }
            source.setCancelHandler { [self] in closeInput() }
            writeSource = source
            source.resume()
        }

        private func write(_ fd: Int32) {
            guard let inputData else { return }
            for _ in 0..<8 {
                let size = min(16384, inputData.count - inputOffset)
                let count = inputData.withUnsafeBytes {
                    Darwin.write(fd, $0.baseAddress?.advanced(by: inputOffset), size)
                }
                if count > 0 {
                    inputOffset += count
                    if inputOffset == inputData.count {
                        stopWriting()
                        return
                    }
                } else if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    if code == EAGAIN || code == EWOULDBLOCK { return }
                    inputError = Self.systemError(code)
                    ChildProcess.stop(child)
                    stopWriting()
                    return
                }
            }
        }

        private func stopReading() {
            readSource?.cancel()
            readSource = nil
        }

        private func stopWriting() {
            writeSource?.cancel()
            writeSource = nil
        }

        private func closeInput() {
            try? input.fileHandleForWriting.close()
            inputData = nil
            inputClosed = true
            finishIfReady()
        }

        private func didTerminate(_ status: Int32) {
            self.status = status
            if writeSource != nil {
                inputError = Self.systemError(EPIPE)
                stopWriting()
            }
            finishIfReady()
        }

        private func finishIfReady() {
            guard inputClosed, outputClosed, let status, let continuation else { return }
            self.continuation = nil
            if owner.didFinish() { continuation.resume(throwing: CancellationError()) }
            else if let outputError { continuation.resume(throwing: outputError) }
            else if status == 0, let inputError { continuation.resume(throwing: inputError) }
            else { continuation.resume(returning: CommandResult(status: status, output: String(decoding: retained, as: UTF8.self))) }
        }

        private static func makeNonblocking(_ fd: Int32) throws {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw systemError(errno) }
        }

        private static func systemError(_ code: Int32) -> POSIXError {
            POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
