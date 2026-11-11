import TermviaCore

/// Presentation ranges belong to the sampler's session, not the currently
/// attached sidebar. Background samples grow them too; tab switches never do.
struct MonitorPlotBounds {
    private(set) var load = 0.0
    private var network: [String: Double] = [:]
    private var disks: [String: Double] = [:]

    func network(device: String?) -> Double { network[device ?? ""] ?? 1 }
    func disk(device: String?) -> Double { disks[device ?? ""] ?? 1 }

    mutating func append(_ sample: MetricsSample) {
        load = Self.growing(load, peak: sample.snapshot.load.max() ?? 0)
        // Empty key represents the aggregate, independently of each device.
        for (name, rate) in sample.network { network[name] = Self.growing(network[name] ?? 0, peak: max(rate.read, rate.write)) }
        for (name, rate) in sample.disks { disks[name] = Self.growing(disks[name] ?? 0, peak: max(rate.read, rate.write)) }
        if let rate = sample.networkRate(device: nil) { network[""] = Self.growing(network[""] ?? 0, peak: max(rate.read, rate.write)) }
        if let rate = sample.diskRate(device: nil) { disks[""] = Self.growing(disks[""] ?? 0, peak: max(rate.read, rate.write)) }
    }

    private static func growing(_ current: Double, peak: Double) -> Double {
        guard peak.isFinite, peak > 0 else { return current }
        return current == 0 || peak > current * 0.9 ? max(current, MonitorPlotScale.upperBound(for: peak)) : current
    }
}
