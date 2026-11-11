import SwiftUI
import TermviaCore

struct LoginSettings: View {
    @ObservedObject var model: AppModel
    @State private var editingCredential: LoginCredential?
    @State private var credentialPresented = false
    @State private var editingHost: SSHHost?
    var body: some View {
        Form {
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
    }
}
