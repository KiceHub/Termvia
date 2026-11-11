import SwiftUI
import TermviaCore

struct HostTrustView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let host: SSHHost
    @State private var fingerprints = ""
    @State private var error: String?
    @State private var busy = false
    @State private var confirm = false
    private var store: KnownHostsStore { KnownHostsStore(url: URL(fileURLWithPath: model.commands.knownHosts)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(T("主机指纹"), systemImage: "checkmark.shield").font(.headline)
            Text("\(host.address):\(host.port)").font(.callout.monospaced()).textSelection(.enabled)
            if let warning = model.hostTrustWarning { Text(warning).font(.caption).foregroundStyle(.red).lineLimit(6).textSelection(.enabled) }
            if busy { ProgressView().controlSize(.small) }
            ScrollView {
                Text(fingerprints.isEmpty ? T("没有已保存的主机指纹") : fingerprints)
                    .font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button(T("忘记指纹…"), role: .destructive) { confirm = true }.disabled(busy || fingerprints.isEmpty)
                Spacer()
                Button(T("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520, height: model.hostTrustWarning == nil ? 320 : 440).workspaceEnvironment(model: model)
            .task { await load() }
            .alert(T("忘记此地址的主机指纹？"), isPresented: $confirm) {
                Button(T("忘记指纹"), role: .destructive) {
                    Task {
                        busy = true
                        do { try await store.forget(host); fingerprints = ""; error = nil }
                        catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }
                Button(T("取消"), role: .cancel) {}
            } message: { Text(T("下次连接必须重新核对并确认指纹。已打开的会话不会中断；同一地址的配置共用此信任记录。")) }
    }
    private func load() async {
        busy = true; defer { busy = false }
        do { fingerprints = try await store.fingerprints(for: host) }
        catch { self.error = error.localizedDescription }
    }
}
