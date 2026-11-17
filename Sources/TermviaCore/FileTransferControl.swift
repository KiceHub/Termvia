import Foundation

public enum FileByteCount {
    public static func adding(_ first: UInt64, _ second: UInt64) -> UInt64 {
        let (sum, overflow) = first.addingReportingOverflow(second); return overflow ? UInt64.max : sum
    }
}
public struct FileTransferProgress: Sendable {
    public let completed: UInt64
    public let total: UInt64
    public let bytesPerSecond: Double
}
/// Pause at protocol block boundaries; the authenticated SSH channel stays open.
public final class FileTransferControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false, cancelled = false, declared = false
    private var completed: UInt64 = 0, total: UInt64 = 0, previous: UInt64 = 0
    private var files = Set<String>()
    private var tick = Date.timeIntervalSinceReferenceDate
    private var preservePermissions = true
    private var progressCallback: (@Sendable (FileTransferProgress) -> Void)?
    public var preserveFilePermissions: Bool {
        get { condition.lock(); defer { condition.unlock() }; return preservePermissions }
        set { condition.lock(); preservePermissions = newValue; condition.unlock() }
    }
    public var onProgress: (@Sendable (FileTransferProgress) -> Void)? {
        get { condition.lock(); defer { condition.unlock() }; return progressCallback }
        set { condition.lock(); progressCallback = newValue; condition.unlock() }
    }
    public init() {}
    public var isPaused: Bool { condition.lock(); defer { condition.unlock() }; return paused }
    public var snapshot: FileTransferProgress { condition.lock(); defer { condition.unlock() }; return FileTransferProgress(completed: completed, total: total, bytesPerSecond: 0) }
    public func pause() { condition.lock(); paused = true; condition.unlock() }
    public func resume() { condition.lock(); paused = false; tick = Date.timeIntervalSinceReferenceDate; previous = completed; condition.broadcast(); condition.unlock() }
    public func cancel() { condition.lock(); cancelled = true; condition.broadcast(); condition.unlock() }
    public func checkpoint() throws {
        condition.lock(); defer { condition.unlock() }
        while paused && !cancelled { condition.wait() }
        if cancelled { throw CancellationError() }
    }
    public func setTotal(_ bytes: UInt64) { condition.lock(); total = bytes; declared = true; condition.unlock(); emit(force: true) }
    public func beginFile(_ path: String, size: UInt64) { condition.lock(); if !declared && files.insert(path).inserted { total = FileByteCount.adding(total, size) }; condition.unlock(); emit(force: true) }
    public func advance(_ bytes: Int) { condition.lock(); completed = FileByteCount.adding(completed, UInt64(max(0, bytes))); if total > 0 { total = max(total, completed) }; condition.unlock(); emit(force: false) }
    public func finish() { emit(force: true) }
    private func emit(force: Bool) {
        condition.lock()
        let now = Date.timeIntervalSinceReferenceDate, elapsed = now - tick
        guard force || elapsed >= 0.15 else { condition.unlock(); return }
        let value = FileTransferProgress(completed: completed, total: total, bytesPerSecond: elapsed > 0 ? Double(completed - previous) / elapsed : 0)
        previous = completed; tick = now
        let callback = progressCallback; condition.unlock(); callback?(value)
    }
}
