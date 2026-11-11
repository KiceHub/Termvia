import Foundation
import TermviaCore

@MainActor final class RemoteMonitor: ObservableObject {
    @Published private(set) var history = MetricsHistory()
    private(set) var plotBounds = MonitorPlotBounds()
    @Published private(set) var status = "等待连接"
    @Published private(set) var detail = ""
    @Published private(set) var running = false
    @Published var networkInterface: String? { didSet { if oldValue != networkInterface { selectionChanged?(selection) } } }
    @Published var diskDevice: String? { didSet { if oldValue != diskDevice { selectionChanged?(selection) } } }
    var selectionChanged: ((MonitorSelection) -> Void)?
    var selection: MonitorSelection { MonitorSelection(networkInterface: networkInterface, diskDevice: diskDevice) }
    func restoreSelection(_ value: MonitorSelection) {
        let value = value.validated(); networkInterface = value.networkInterface; diskDevice = value.diskDevice
    }
    typealias StreamRunner = @MainActor (Invocation, @escaping @Sendable (Data) -> Void) async throws -> CommandResult
    private let streamRunner: StreamRunner?
    init(streamRunner: StreamRunner? = nil) { self.streamRunner = streamRunner }
    private var generation = UUID()
    private var job: Task<Void, Never>?
    private(set) var interval = 1
    var latest: MetricsSample? { history.samples.last }
    var effectiveNetworkInterface: String? { networkInterface.flatMap { latest?.snapshot.network[$0] == nil ? nil : $0 } }
    var effectiveDiskDevice: String? { diskDevice.flatMap { latest?.snapshot.disks[$0] == nil ? nil : $0 } }
    func receive(_ snapshot: RemoteSnapshot) {
        history.append(snapshot, interval: Double(interval))
        if history.samples.count == 1 { plotBounds = MonitorPlotBounds() }
        if let sample = latest { plotBounds.append(sample) }
        if status != "实时" { status = "实时" }
        if !detail.isEmpty { detail = "" }
    }
    func stop() { job?.cancel(); running = false; history.pause(); status = "已暂停"; detail = "" }
    func stopAndWait() async { let worker = job; stop(); await worker?.value }
    func showsWarning(at date: Date) -> Bool {
        ["监控失败", "监控已断开", "仅支持 Linux 和 macOS 监控"].contains(status) || (running && status == "实时" && latest.map { date.timeIntervalSince($0.snapshot.time) > max(10, Double(interval) * 3) } == true)
    }
    func run(host: SSHHost?, authentication: AuthenticationContext?, commands: SSHCommands, interval: Int = 1) async {
        guard !Task.isCancelled else { return }
        job?.cancel()
        self.interval = min(30, max(1, interval))
        let token = UUID(); generation = token
        history.pause(); status = "正在采样"; detail = ""; running = true
        let sampleInterval = self.interval
        let worker = Task { [weak self] in
            do {
                if host == nil {
                    let clock = ContinuousClock()
                    var next = clock.now
                    while !Task.isCancelled {
                        let snapshot = try await LocalMetricsSampler.shared.sample()
                        try Task.checkCancellation()
                        guard let self, self.generation == token else { throw CancellationError() }
                        self.receive(snapshot)
                        next = max(next.advanced(by: .seconds(sampleInterval)), clock.now)
                        try await clock.sleep(until: next, tolerance: .milliseconds(50))
                    }
                    return
                }
                var failures = 0
                while !Task.isCancelled {
                    guard let self, self.generation == token else { return }
                    self.history.pause()
                    let started = ContinuousClock.now
                    let (result, diagnostic, sampled) = try await self.sampleRemote(host: host, authentication: authentication, commands: commands, interval: sampleInterval, token: token)
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    self.status = result.status == 42 ? "仅支持 Linux 和 macOS 监控" : "监控已断开"
                    self.detail = result.status == 0 || result.status == 42 ? "" : diagnostic
                    guard MonitorRetryPolicy.shouldRetry(status: result.status, diagnostic: diagnostic) else { break }
                    // A server that drops every newly opened channel must not
                    // trigger a rapid reconnect loop just because it sent one frame.
                    if sampled, started.duration(to: .now) >= .seconds(30) { failures = 0 }
                    failures = min(5, failures + 1)
                    self.history.pause()
                    try await Task.sleep(for: .seconds(MonitorRetryPolicy.delay(afterFailure: failures)))
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    self.status = "正在采样"
                }
            } catch is CancellationError {} catch {
                guard let self, self.generation == token else { return }
                self.status = "监控失败"; self.detail = error.localizedDescription
            }
        }
        job = worker
        await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        if generation == token {
            job = nil; running = false; history.pause()
            if status == "实时" || status == "正在采样" { status = "已暂停" }
        }
    }

    private func sampleRemote(host: SSHHost?, authentication: AuthenticationContext?, commands: SSHCommands, interval: Int, token: UUID) async throws -> (CommandResult, String, Bool) {
        try Task.checkCancellation()
        let lease = try authentication?.lease(allowPrompts: false); defer { lease?.close() }
        let decoder = MetricsDecoder()
        let (snapshots, continuation) = AsyncThrowingStream<RemoteSnapshot, Error>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let output: @Sendable (Data) -> Void = { bytes in
            do { for snapshot in try decoder.feed(bytes) { continuation.yield(snapshot) } }
            catch { continuation.finish(throwing: error) }
        }
        let invocation = try host.map { try RemoteSampler.remoteInvocation($0, commands: commands, interval: interval) } ?? RemoteSampler.localInvocation(interval: interval)
        let streamRunner = self.streamRunner
        let process = Task {
            defer { continuation.finish() }
            if let streamRunner { return try await streamRunner(invocation, output) }
            if let lease { return try await lease.run(invocation, outputLimit: 0, onOutput: output) }
            return try await ProcessRunner().run(invocation, outputLimit: 0, onOutput: output)
        }
        var sampled = false
        let result = try await withTaskCancellationHandler(operation: {
            do {
                for try await snapshot in snapshots {
                    try Task.checkCancellation()
                    guard generation == token else { throw CancellationError() }
                    lease?.confirmAuthentication(); receive(snapshot); sampled = true
                }
                return try await process.value
            } catch {
                process.cancel(); continuation.finish(); _ = try? await process.value
                throw error
            }
        }, onCancel: { process.cancel(); continuation.finish() })
        return (result, decoder.diagnosticOutput, sampled)
    }
}
