import SwiftUI
import TermviaCore

struct HostFingerprintSettings: View {
    @ObservedObject var model: AppModel
    @State private var records: [KnownHostRecord] = []
    @State private var addresses: [String: String] = [:]
    @State private var query = ""
    @State private var busy = false
    @State private var loaded = false
    @State private var error: String?
    @State private var pending: KnownHostRecord?
    private var store: KnownHostsStore { KnownHostsStore(url: URL(fileURLWithPath: model.commands.knownHosts)) }
    private var visible: [KnownHostRecord] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? records : records.filter {
            [addresses[$0.id] ?? $0.hosts, $0.hosts, $0.keyType, $0.fingerprint].contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }
    var body: some View {
        Group {
            HStack {
                TextField(T("搜索主机指纹"), text: $query, prompt: Text(T("搜索主机指纹")))
                    .textFieldStyle(.roundedBorder).labelsHidden()
                    .accessibilityIdentifier("Termvia.Fingerprints.Search")
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(T("刷新")).accessibilityLabel(T("刷新"))
                    .accessibilityIdentifier("Termvia.Fingerprints.Refresh").disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }
            .task { await load() }
            .compactAlert(T("忘记此指纹？"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                          message: pending.map(confirmationMessage) ?? "", actions: [
                .init(T("忘记指纹")) {
                    guard let record = pending else { return }
                    Task {
                        busy = true
                        do { try await model.forgetFingerprint(record); await load() }
                        catch { self.error = error.localizedDescription }
                        busy = false
                    }
                },
                .init(T("取消"), role: .cancel)
            ])
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if loaded && records.isEmpty && error == nil {
                Text(T("没有已保存的主机指纹")).foregroundStyle(.secondary)
                    .accessibilityIdentifier("Termvia.Fingerprints.Empty")
            } else if loaded && visible.isEmpty && !records.isEmpty {
                Text(T("没有匹配的主机指纹")).foregroundStyle(.secondary)
            }
            ForEach(visible) { record in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(addresses[record.id] ?? (record.isHashed ? T("隐藏的主机地址") : record.hosts))
                                .lineLimit(1).textSelection(.enabled).help(record.hosts).accessibilityIdentifier("Termvia.Fingerprints.Address")
                            Text(([record.marker, record.keyType].filter { !$0.isEmpty }).joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 2).background(.quaternary, in: Capsule()).fixedSize()
                                .accessibilityIdentifier("Termvia.Fingerprints.Type")
                        }
                        Text(record.fingerprint).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            .accessibilityIdentifier("Termvia.Fingerprints.Value")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button(role: .destructive) { pending = record } label: { Image(systemName: "trash").frame(width: 16, height: 16) }
                        .buttonStyle(.bordered).controlSize(.small).help(T("忘记指纹…")).accessibilityLabel(T("忘记指纹…"))
                        .disabled(busy).accessibilityIdentifier("Termvia.Fingerprints.Forget")
                }.padding(.vertical, 3)
            }
        }
    }
    private func confirmationMessage(_ record: KnownHostRecord) -> String {
        let address = addresses[record.id] ?? record.hosts
        let explanation = T("下次连接可能需重新确认指纹。")
        return "\(address)\n\(record.fingerprint)\n\n\(explanation)"
    }
    private func load() async {
        busy = true; defer { busy = false; loaded = true }
        do {
            let values = try await store.records()
            var names: [String: String] = [:]
            for record in values where record.isHashed {
                if let host = model.hosts.first(where: { record.matches(address: $0.address, port: $0.port) }) {
                    names[record.id] = host.port == 22 ? host.address : "[\(host.address)]:\(host.port)"
                }
            }
            addresses = names; records = values; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
