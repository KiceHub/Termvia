import SwiftUI
import TermviaCore

struct MonitorSidebar: View {
    let session: Session?
    let sessionCount: Int
    var scrollable = true
    var model: AppModel? = nil
    var body: some View {
        if let session, !session.isStartPage, let model {
            LiveMonitorView(session: session, model: model, enabled: scrollable)
                // A new session attaches at its own latest position. Never
                // interpolate between two hosts' clocks or view state.
                .id(session.id)
        }
        else { EmptyPane(symbol: "chart.xyaxis.line", title: "等待 SSH 连接", detail: "") }
    }
}
struct MetricPoint: Identifiable {
    let id: String
    let time: Date
    let value: Double
    let series: String
    var samplingInterval: TimeInterval? = nil
}
struct MetricPlot: View {
    let title: String
    let value: String
    let points: [MetricPoint]
    var percent = false
    var selector: AnyView? = nil
    var series: [String] = []
    var windowEnd: Date? = nil
    var samplingInterval = 1.0
    var animationDuration = 0.0
    var scaleKey = ""
    var scaleUpperBound: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale = 0.0
    var body: some View {
        let multipleSeries = series.count > 1 || Set(points.map(\.series)).count > 1
        let end = windowEnd ?? points.map(\.time).max() ?? Date()
        let retainedInterval = max(samplingInterval, points.compactMap(\.samplingInterval).max() ?? samplingInterval)
        let visible = points.filter { $0.time >= end.addingTimeInterval(-MetricPlotViewport.drawingDuration - retainedInterval * 2) && $0.time <= end }
        let maximum = visible.reduce(0.0) { max($0, $1.value) }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle).help(title)
                Spacer(minLength: 8)
                if let selector { selector }
                else { Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8) }
            }
            if selector != nil { Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8) }
            let domain = series.isEmpty ? [title] : series
            let bound = percent ? 100 : scaleUpperBound ?? (scale > 0 ? scale : MonitorPlotScale.upperBound(for: maximum))
            let curves = domain.map { name in MetricCurve(points: visible.filter { $0.series == name }, maximumGap: max(3, samplingInterval * 2.5)) }
            VStack(alignment: .leading, spacing: 3) {
                ScrollingMetricCanvas(end: end.timeIntervalSinceReferenceDate, upperBound: bound, curves: curves, duration: animationDuration > 0 ? animationDuration : samplingInterval, animateScale: !reduceMotion && (scaleUpperBound != nil || scale > 0), animateScroll: !reduceMotion && animationDuration > 0)
                    .id(scaleKey)
                    .frame(height: 48)
#if TERMVIA_DIAGNOSTICS
                    .background(GeometryCheckProbe(role: "plot-" + title.lowercased()))
#endif

                    .accessibilityLabel(title + ": " + value)
                if multipleSeries {
                    HStack(spacing: 10) {
                        ForEach(Array(domain.enumerated()), id: \.offset) { index, name in
                            HStack(spacing: 4) {
                                Circle().fill([Color.blue, Color.orange, Color.purple][min(2, index)]).frame(width: 7, height: 7)
                                Text(name).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(height: 17)
                }
            }
            .onChange(of: maximum, initial: true) { _, peak in
                guard !percent, scaleUpperBound == nil, peak > 0 else { return }
                let next = MonitorPlotScale.upperBound(for: peak)
                if scale == 0 || peak > scale * 0.9 { scale = max(scale, next) }
            }
            .onChange(of: scaleKey) { _, _ in
                guard scaleUpperBound == nil else { return }
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { scale = MonitorPlotScale.upperBound(for: maximum) }
            }
        }
#if TERMVIA_DIAGNOSTICS
        .background(GeometryCheckProbe(role: "monitor-" + title.lowercased()))
#endif

    }
}
private struct LiveMonitorView: View {
    @ObservedObject var session: Session
    @ObservedObject private var monitor: RemoteMonitor
    @ObservedObject var model: AppModel
    let enabled: Bool
    init(session: Session, model: AppModel, enabled: Bool) { self.session = session; self.monitor = session.monitor; self.model = model; self.enabled = enabled }
    private var snapshot: RemoteSnapshot? { monitor.latest?.snapshot }
    private var plotAnimationDuration: Double {
        let samples = monitor.history.samples
        guard samples.count > 1 else { return 0 }
        return min(Double(monitor.interval) * 2, max(0.25, samples[samples.count - 1].snapshot.time.timeIntervalSince(samples[samples.count - 2].snapshot.time)))
    }
    private func number(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
    private func bytes(_ value: Double?) -> String { value.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: UInt64(max(0, min(Double(UInt64.max / 2), $0)))), countStyle: .file) } ?? "—" }
    private func points(_ series: String, _ value: (MetricsSample) -> Double?) -> [MetricPoint] {
        monitor.history.samples.compactMap { sample in value(sample).map { MetricPoint(id: sample.id.uuidString + series, time: sample.snapshot.time, value: $0, series: series, samplingInterval: sample.samplingInterval) } }
    }
    private func selectedDevice(_ disk: Bool) -> String? { disk ? monitor.effectiveDiskDevice : monitor.effectiveNetworkInterface }
    private func io(_ disk: Bool) -> [MetricPoint] {
        let device = selectedDevice(disk)
        return points(T(disk ? "读取" : "接收")) { (disk ? $0.diskRate(device: device) : $0.networkRate(device: device))?.read }
            + points(T(disk ? "写入" : "发送")) { (disk ? $0.diskRate(device: device) : $0.networkRate(device: device))?.write }
    }
    private func options(_ disk: Bool) -> [String] {
        (disk ? snapshot?.disks.keys.sorted() : snapshot?.network.keys.sorted()) ?? []
    }
    private func devicePicker(_ disk: Bool) -> some View {
        let choices: [(value: String?, title: String)] = [(nil, T("全部"))] + options(disk).map { ($0, $0) }
        let selection = Binding<String?>(get: { selectedDevice(disk) }, set: { if disk { monitor.diskDevice = $0 } else { monitor.networkInterface = $0 } })
        return NativePopUpPicker(selection: selection, options: choices,
                                 label: disk ? "磁盘" : "网卡", identifier: disk ? "Termvia.Monitor.Disk" : "Termvia.Monitor.Network")
            .frame(width: 86)
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(snapshot.flatMap { $0.hostname.isEmpty ? nil : $0.hostname } ?? session.title).font(.headline).lineLimit(1).textSelection(.enabled)
                            Spacer(minLength: 0)
                            TimelineView(.periodic(from: .now, by: 3)) { context in
                                let warning = monitor.showsWarning(at: context.date)
                                Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                                    .opacity(warning ? 1 : 0).accessibilityHidden(!warning).allowsHitTesting(warning)
                                    .help(T(monitor.status)).frame(width: 14, height: 14)
                            }
                        }
                        Text(snapshot?.system ?? "—").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(snapshot.map { $0.kernel.isEmpty ? "—" : $0.kernel } ?? "—").font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        Text(snapshot?.processor ?? "—").font(.caption2).lineLimit(2).help(snapshot?.processor ?? "")
                        Text(snapshot.map { ($0.architecture.isEmpty ? "—" : $0.architecture) + " · " + MonitorCPUFormatter.string(cores: $0.cores, threads: $0.threads) + " · " + MonitorUptimeFormatter.string($0.uptime) } ?? "—")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
                            .accessibilityIdentifier("Termvia.Monitor.ArchitectureCores")
                    }
#if TERMVIA_DIAGNOSTICS
                    .background(GeometryCheckProbe(role: "monitor-info"))
#endif

                    plots(endingAt: snapshot?.time ?? .now)
                    if !monitor.detail.isEmpty { Text(monitor.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled) }
                }.padding(12)
            }.controlSize(.small)
                .contextMenu { Button(T("重新采样")) { model.resample(session) }.disabled(!enabled || !session.readyForMonitoring || !session.sidebarVisible) }
            if session.host != nil {
                HostClockFooter(snapshot: snapshot, advancing: monitor.running && session.connected)
            }
        }
    }
    private func plots(endingAt date: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            MetricPlot(title: "CPU", value: monitor.latest?.cpuPercent.map { number($0) + "%" } ?? "—", points: points("CPU") { $0.cpuPercent }, percent: true, windowEnd: date, samplingInterval: Double(monitor.interval), animationDuration: plotAnimationDuration)
            MetricPlot(title: "MEM", value: bytes(snapshot?.memoryUsed) + " / " + bytes(snapshot?.memoryTotal), points: points("MEM") { $0.snapshot.memoryPercent }, percent: true, windowEnd: date, samplingInterval: Double(monitor.interval), animationDuration: plotAnimationDuration)
            if model.showsLoad(for: session) {
                MetricPlot(title: "LOAD", value: snapshot.flatMap { $0.load.isEmpty ? nil : $0.load.map { String(format: "%.2f", $0) }.joined(separator: " / ") } ?? "—", points: points("1m") { $0.snapshot.load.first } + points("5m") { $0.snapshot.load.count > 1 ? $0.snapshot.load[1] : nil } + points("15m") { $0.snapshot.load.count > 2 ? $0.snapshot.load[2] : nil }, series: ["1m", "5m", "15m"], windowEnd: date, samplingInterval: Double(monitor.interval), animationDuration: plotAnimationDuration, scaleUpperBound: monitor.plotBounds.load > 0 ? monitor.plotBounds.load : 1).help(T("1 / 5 / 15 分钟平均负载"))
            }
            MetricPlot(title: "NET", value: rateDescription(monitor.latest?.networkRate(device: selectedDevice(false)), disk: false), points: io(false), selector: AnyView(devicePicker(false)), series: [T("接收"), T("发送")], windowEnd: date, samplingInterval: Double(monitor.interval), animationDuration: plotAnimationDuration, scaleKey: selectedDevice(false) ?? "all", scaleUpperBound: monitor.plotBounds.network(device: selectedDevice(false)))
            if snapshot?.network.isEmpty == true { Text(T("未检测到物理网卡")).font(.caption2).foregroundStyle(.secondary) }
            MetricPlot(title: "DISK", value: rateDescription(monitor.latest?.diskRate(device: selectedDevice(true)), disk: true), points: io(true), selector: AnyView(devicePicker(true)), series: [T("读取"), T("写入")], windowEnd: date, samplingInterval: Double(monitor.interval), animationDuration: plotAnimationDuration, scaleKey: selectedDevice(true) ?? "all", scaleUpperBound: monitor.plotBounds.disk(device: selectedDevice(true)))
            DiskCapacityGauge(space: snapshot?.diskSpace(device: selectedDevice(true)))
#if TERMVIA_DIAGNOSTICS
            .background(GeometryCheckProbe(role: "monitor-capacity"))
#endif

            if snapshot?.disks.isEmpty == true && snapshot?.diskSpace(device: nil) == nil { Text(T("未检测到物理磁盘")).font(.caption2).foregroundStyle(.secondary) }
        }
    }
    private func rateDescription(_ rate: IORate?, disk: Bool) -> String {
        let read = MonitorRateFormatter.string(rate?.read), write = MonitorRateFormatter.string(rate?.write)
        return disk ? "W \(write) · R \(read)" : "↑ \(write) · ↓ \(read)"
    }
}

private struct HostClockFooter: View {
    let snapshot: RemoteSnapshot?
    let advancing: Bool
    var body: some View {
        Group {
            if advancing {
                TimelineView(.periodic(from: .now, by: 1)) { context in time(at: context.date) }
            } else { time(at: snapshot?.time ?? .now) }
        }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)

#if TERMVIA_DIAGNOSTICS
            .background(GeometryCheckProbe(role: "monitor-clock"))
#endif

    }
    private func time(at date: Date) -> some View {
        let value = snapshot.flatMap { sample in sample.hostClock?.formatted(at: date, sampledAt: sample.time, advancing: advancing) } ?? "—"
        return Text(value)
            .lineLimit(1).minimumScaleFactor(0.8)
            .accessibilityIdentifier("Termvia.Monitor.HostTime").accessibilityLabel(T("远程主机时间"))
            .accessibilityValue(value)
            .help(T("远程主机时间"))
    }
}

struct DiskCapacityGauge: View {
    @Environment(\.locale) private var locale
    let space: DiskSpace?
    private var amounts: (used: String, remaining: String, display: String) {
        guard let space else { return ("—", "—", "— / —") }
        let maximum = max(space.used, space.remaining)
        let unit = maximum >= 1e12 ? 1e12 : maximum >= 1e9 ? 1e9 : maximum >= 1e6 ? 1e6 : maximum >= 1e3 ? 1e3 : 1
        let suffix = unit == 1e12 ? "TB" : unit == 1e9 ? "GB" : unit == 1e6 ? "MB" : unit == 1e3 ? "KB" : "B"
        let format = FloatingPointFormatStyle<Double>.number.locale(locale).precision(.significantDigits(1...3))
        let used = (space.used / unit).formatted(format), remaining = (space.remaining / unit).formatted(format)
        return (used + " " + suffix, remaining + " " + suffix, used + " / " + remaining + " " + suffix)
    }
    var body: some View {
        let values = amounts
        HStack(spacing: 8) {
            Gauge(value: space?.used ?? 0, in: 0...max(1, space?.total ?? 1)) { EmptyView() }
                .gaugeStyle(.linearCapacity).tint(space == nil ? Color.gray : AppTheme.accent).disabled(space == nil)
                .frame(minWidth: 36, maxWidth: .infinity)
                .accessibilityIdentifier("Termvia.Monitor.Capacity.Bar")
            Text(values.display).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false).accessibilityIdentifier("Termvia.Monitor.Capacity.Value")
        }.accessibilityElement(children: .contain).accessibilityLabel(T("磁盘"))
            .accessibilityValue(T("已用 %@，剩余 %@", values.used, values.remaining))
    }
}
