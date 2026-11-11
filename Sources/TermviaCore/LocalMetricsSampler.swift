import Foundation
import Darwin
import IOKit

/// Local tabs share discovery and near-simultaneous samples. Only discovery
/// launches tools (at most every 30 seconds); steady sampling uses kernel APIs.
public actor LocalMetricsSampler {
    public static let shared = LocalMetricsSampler()
    private var metadata: RemoteSnapshot?
    private var discovery: (id: UUID, task: Task<RemoteSnapshot, Error>)?
    private var discoveryWaiters: [UUID: UUID] = [:]
    private var discoveredAt = -Double.infinity
    private var cached: RemoteSnapshot?
    private var ticks: [UInt32]?
    private var storageDrivers: [String: io_registry_entry_t] = [:]
    private let host = mach_host_self()
    public init() {}
    deinit {
        for driver in storageDrivers.values { IOObjectRelease(driver) }
        mach_port_deallocate(mach_task_self_, host)
    }

    public func sample() async throws -> RemoteSnapshot {
        try Task.checkCancellation()
        let now = ProcessInfo.processInfo.systemUptime
        if let cached, now - cached.counterTime < 0.2 { return cached }
        if metadata == nil || now - discoveredAt >= 30 {
            let work: (id: UUID, task: Task<RemoteSnapshot, Error>)
            if let discovery { work = discovery }
            else {
                let task = Task {
                    let runner = ProcessRunner()
                    let timeout = DispatchWorkItem { runner.cancel() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
                    defer { timeout.cancel() }
                    let result = try await runner.run(RemoteSampler.localInvocation(samples: 1), outputLimit: 263168)
                    guard result.status == 0, let snapshot = try MetricsDecoder().feed(Data(result.output.utf8)).last else { throw MetricsError.invalid }
                    return snapshot
                }
                work = (UUID(), task); discovery = work
            }
            let waiter = UUID(); discoveryWaiters[waiter] = work.id
            defer { discoveryWaiters[waiter] = nil }
            do {
                let refreshed = try await withTaskCancellationHandler(operation: {
                    try await work.task.value
                }, onCancel: {
                    Task { await self.cancelDiscovery(waiter: waiter, id: work.id) }
                })
                try Task.checkCancellation()
                if discovery?.id == work.id { discovery = nil }
                metadata = refreshed; discoveredAt = ProcessInfo.processInfo.systemUptime
                refreshStorage(physical: refreshed.physicalDisks)
            } catch is CancellationError {
                if work.task.isCancelled, discovery?.id == work.id { discovery = nil }
                throw CancellationError()
            } catch {
                if discovery?.id == work.id { discovery = nil }
                // Transient filesystem discovery failures must not stop fast metrics.
                guard metadata != nil else { throw error }
                discoveredAt = ProcessInfo.processInfo.systemUptime
            }
        }
        try Task.checkCancellation()
        // Another tab may have filled the cache while discovery was suspended.
        if let cached, ProcessInfo.processInfo.systemUptime - cached.counterTime < 0.2 { return cached }
        guard let metadata else { throw MetricsError.invalid }
        var cpu = host_cpu_load_info_data_t(), cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let cpuStatus = withUnsafeMutablePointer(to: &cpu) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount) }
        }
        var vm = vm_statistics64_data_t(), vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let vmStatus = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(host, HOST_VM_INFO64, $0, &vmCount) }
        }
        let current = [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3]
        var percentage: Double?
        if cpuStatus == KERN_SUCCESS, let ticks {
            let delta = zip(current, ticks).map { Double($0 &- $1) }, total = delta.reduce(0, +)
            if total > 0 { percentage = max(0, min(100, 100 * (1 - delta[Int(CPU_STATE_IDLE)] / total))) }
        }
        ticks = cpuStatus == KERN_SUCCESS ? current : nil
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) != 3 { loads = [] }
        let uptime = ProcessInfo.processInfo.systemUptime, date = Date()
        let available = (Double(vm.free_count) + Double(vm.inactive_count) + Double(vm.speculative_count)) * Double(vm_kernel_page_size)
        let network = (try? Self.network(physical: metadata.physicalNetworkInterfaces)) ?? ""
        let disks = storage()
        let cpuField = percentage.map { "[cpu-percent]\n\($0)" } ?? "[cpu-baseline]"
        let offset = TimeZone.current.secondsFromGMT(for: date), minutes = abs(offset) / 60
        let zone = String(format: "%@%02d%02d", offset < 0 ? "-" : "+", minutes / 60, minutes % 60)
        let text = """
        [uptime]
        \(uptime)
        [counter-time]
        \(uptime)
        [clock]
        \(date.timeIntervalSince1970) \(zone)
        \(cpuField)
        [memory]
        MemTotal: \(UInt64((metadata.memoryTotal ?? Double(ProcessInfo.processInfo.physicalMemory)) / 1024)) kB
        \(vmStatus == KERN_SUCCESS ? "MemAvailable: \(UInt64(available / 1024)) kB" : "")
        [load]
        \(loads.map(String.init(describing:)).joined(separator: " "))
        [network-compact]
        \(network)
        [disks-compact]
        \(disks)
        """
        let snapshot = try RemoteSnapshot.parse(text, time: date, inheriting: metadata)
        cached = snapshot
        return snapshot
    }

    private func cancelDiscovery(waiter: UUID, id: UUID) {
        discoveryWaiters[waiter] = nil
        guard discovery?.id == id, !discoveryWaiters.values.contains(id) else { return }
        discovery?.task.cancel(); discovery = nil
    }

    private static func network(physical: Set<String>) throws -> String {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0], size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size <= 4 * 1024 * 1024 else { throw MetricsError.invalid }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &bytes, &size, nil, 0) == 0 else { throw MetricsError.invalid }
        return bytes.withUnsafeBytes { buffer in
            var offset = 0, rows: [String] = []
            while offset + 4 <= size {
                let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, offset + length <= size else { break }
                // Address records interleave with interface records and have
                // smaller headers. Skip them without truncating the inventory.
                if buffer[offset + 3] == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
                    let message = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(message.ifm_index), &name) != nil {
                        let device = String(cString: name)
                        if physical.contains(device) { rows.append("\(device) \(message.ifm_data.ifi_ibytes) \(message.ifm_data.ifi_obytes)") }
                    }
                }
                offset += length
            }
            return rows.joined(separator: "\n")
        }
    }
    private func refreshStorage(physical: Set<String>) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var found: [String: io_registry_entry_t] = [:]
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            if let name = IORegistryEntrySearchCFProperty(driver, kIOServicePlane, "BSD Name" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)) as? String,
               physical.contains(name), found[name] == nil { found[name] = driver }
            else { IOObjectRelease(driver) }
        }
        for driver in storageDrivers.values { IOObjectRelease(driver) }
        storageDrivers = found
    }
    private func storage() -> String {
        storageDrivers.compactMap { name, driver in
            guard let stats = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                  let read = stats["Bytes (Read)"] as? NSNumber, let write = stats["Bytes (Write)"] as? NSNumber else { return nil }
            return "\(name) \(read.uint64Value) \(write.uint64Value)"
        }.joined(separator: "\n")
    }
}
