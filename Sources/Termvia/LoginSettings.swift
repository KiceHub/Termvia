import SwiftUI
import TermviaCore

struct LoginSettings: View {
    @ObservedObject var model: AppModel
    @State private var editingCredential: LoginCredential?
    @State private var credentialPresented = false
    @State private var editingHost: SSHHost?
    @State private var confirmLocalStorage = false
    @State private var storageMessage: String?
    var body: some View {
        Form {
            if model.canChangeKeychainStorage {
                Section {
                    Toggle(T("使用 macOS 钥匙串"), isOn: Binding(get: { model.keychainChoice == true }, set: { enabled in
                        if enabled { setKeychainStorage(true) } else { confirmLocalStorage = true }
                    }))
                    .disabled(model.changingKeychainStorage)
                    .accessibilityIdentifier("Termvia.Login.KeychainStorage")
                } footer: {
                    Text(T("适用于已保存的 SSH 和代理密码、私钥口令及 WireGuard 密钥。关闭时使用未加密的本机文件。"))
                }
            }
            Section(T("共享登录信息")) {
                ForEach(model.credentials) { credential in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(credential.name)
                            Text(credential.user).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(T("编辑…")) { editingCredential = credential; credentialPresented = true }
                    }
                }
                Button { editingCredential = nil; credentialPresented = true } label: { Label(T("新增"), systemImage: "plus") }
                    .accessibilityIdentifier("Termvia.Login.Add")
            }
            if model.hosts.contains(where: { $0.credentialID == nil }) {
                Section(T("主机登录信息")) {
                    ForEach(model.hosts.filter { $0.credentialID == nil }) { host in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(host.name)
                                Text("\(host.user)@\(host.address)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(T("编辑…")) { editingHost = host }
                        }
                    }
                }
            }
            Section {
                HostFingerprintSettings(model: model)
            } header: { Text(T("主机指纹")) }
            footer: { Text(T("包括已删除主机的信任记录；删除主机配置不会清除此列表。")) }
        }.formStyle(.grouped)
            .sheet(isPresented: $credentialPresented) {
                CredentialEditor(model: model, profile: editingCredential, user: "root", method: .password, identity: "") { _ in }
            }
            .sheet(item: $editingHost) { HostManager(model: model, host: $0) }
            .compactAlert(T("将登录信息移到本机文件？"), isPresented: $confirmLocalStorage,
                          message: T("关闭后，已保存的密码和密钥将移到未加密的本机文件。"), actions: [
                .init(T("关闭钥匙串保存")) { setKeychainStorage(false) },
                .init(T("取消"), role: .cancel) {}
            ])
            .compactAlert(T("钥匙串保存"), isPresented: Binding(get: { storageMessage != nil }, set: { if !$0 { storageMessage = nil } }),
                          message: storageMessage ?? "", actions: [.init(T("确定")) {}])
    }
    private func setKeychainStorage(_ enabled: Bool) {
        Task {
            do { storageMessage = try await model.setKeychainStorage(enabled) }
            catch { storageMessage = error.localizedDescription }
        }
    }
}
