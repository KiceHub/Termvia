import AppKit
import SwiftUI
import TermviaCore

struct CredentialEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let profile: LoginCredential?
    let onSave: (UUID) -> Void
    @State private var name: String
    @State private var user: String
    @State private var identity: String
    @State private var secret: String
    @State private var passphrase = ""
    @State private var removeSecret = false
    @State private var deleting = false
    @State private var error: String?
    init(model: AppModel, profile: LoginCredential? = nil, user: String, method: SSHAuthentication, identity: String, secret: String = "", onSave: @escaping (UUID) -> Void) {
        self.model = model; self.profile = profile; self.onSave = onSave
        _name = State(initialValue: profile?.name ?? "")
        _user = State(initialValue: profile?.user ?? user)
        _identity = State(initialValue: profile?.identity ?? identity)
        let values = LoginSecrets(stored: secret, method: method)
        _secret = State(initialValue: values.password)
        _passphrase = State(initialValue: values.passphrase)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(T(profile == nil ? "保存登录信息" : "编辑登录信息")).font(.headline)
            Form {
                TextField(T("名称"), text: $name)
                TextField(T("用户名"), text: $user)
                IdentityField(identity: $identity, passphrase: $passphrase)
                SecureField(T("密码"), text: $secret).disabled(removeSecret)
                if profile != nil { Toggle(T("移除已保存的密码或口令"), isOn: $removeSecret) }
            }.formStyle(.columns).textFieldStyle(.roundedBorder)
            if let profile { Text(T("共享于 %d 台主机", model.credentialUseCount(profile.id))).font(.caption).foregroundStyle(.secondary) }
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red) }
            Spacer(minLength: 0)
            HStack {
                if let profile {
                    Button(T("删除…"), role: .destructive) { deleting = true }
                        .disabled(model.credentialUseCount(profile.id) > 0).help(T("仅可删除未被主机使用的登录信息"))
                }
                Spacer()
                Button(T("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(T("保存")) { save() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 480, height: 360)
            .workspaceEnvironment(model: model)
            .task {
                if let profile {
                    do { let values = try model.loginSecrets(for: profile); secret = values.password; passphrase = values.passphrase }
                    catch { self.error = error.localizedDescription }
                }
            }
            .alert(T("删除此登录信息？"), isPresented: $deleting) {
                Button(T("删除"), role: .destructive) {
                    do { if let profile { try model.deleteCredential(profile) }; onSave(UUID()); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
                Button(T("取消"), role: .cancel) {}
            }
    }
    private func save() {
        let method: SSHAuthentication = identity.isEmpty ? .password : secret.isEmpty ? .privateKey : .keyAndPassword
        let profile = LoginCredential(id: profile?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), user: user,
                                      authentication: method, identity: (identity as NSString).expandingTildeInPath)
        do {
            guard removeSecret || !identity.isEmpty || !secret.isEmpty else { throw SSHError.invalid("请输入密码或选择密钥") }
            let value = try LoginSecrets(password: secret, passphrase: passphrase).stored(method: method)
            let update: CredentialSecretUpdate = removeSecret ? .remove : value.isEmpty ? .keep : .replace(value)
            try model.saveCredential(profile, secret: update)
            secret = ""; onSave(profile.id); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct IdentityField: View {
    @Binding var identity: String
    var passphrase: Binding<String>? = nil
    var body: some View {
        LabeledContent(T("私钥")) { IdentityControls(identity: $identity, passphrase: passphrase) }
    }
}

struct IdentityControls: View {
    @Binding var identity: String
    var passphrase: Binding<String>? = nil
    @State private var editingPassphrase = false
    var body: some View {
        HStack(spacing: 8) {
            TextField(T("选择私钥文件"), text: $identity).labelsHidden()
                .accessibilityIdentifier("Termvia.Host.Identity")
            if let passphrase {
                Button { editingPassphrase = true } label: { Image(systemName: "key") }
                    .help(T("密钥口令")).accessibilityLabel(T("密钥口令"))
                    .popover(isPresented: $editingPassphrase) {
                        VStack(alignment: .leading, spacing: 10) {
                            SecureField(T("密钥口令（可为空）"), text: passphrase)
                            HStack { Spacer(); Button(T("确定")) { editingPassphrase = false }.keyboardShortcut(.defaultAction) }
                        }.padding(14).frame(width: 260)
                    }
            }
            Button {
                let panel = NSOpenPanel(); panel.showsHiddenFiles = true; panel.canChooseDirectories = false
                if panel.runModal() == .OK, let url = panel.url { identity = url.path }
            } label: { Image(systemName: "folder") }.help(T("选择私钥")).accessibilityLabel(T("选择私钥"))
        }
    }
}
