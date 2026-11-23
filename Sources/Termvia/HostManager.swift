import AppKit
import SwiftUI
import TermviaCore

struct HostCopyDraft {
    let host: SSHHost
    let secrets: LoginSecrets
}

struct HostManager: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let host: SSHHost?
    let draft: HostCopyDraft?
    let onSave: (SSHHost) -> Void
    @State private var name: String
    @State private var address: String
    @State private var user: String
    @State private var port: String
    @State private var identity: String
    @State private var group: String
    @State private var fileProtocol: SSHCommands.FileProtocol
    @State private var upstream = ""
    @State private var proxyKind = "none"
    @State private var proxyRequest: ProxyEditorRequest?
    @State private var password = ""
    @State private var passphrase = ""
    @State private var credentialID: UUID?
    @State private var credentialEditor = false
    @State private var editingCredential: LoginCredential?
    @State private var error: String?
    private var selectedCredential: LoginCredential? { model.credentials.first { $0.id == credentialID } }
    private var method: SSHAuthentication { identity.isEmpty ? .password : password.isEmpty ? .privateKey : .keyAndPassword }
    init(model: AppModel, host: SSHHost? = nil, defaultGroup: String? = nil, draft: HostCopyDraft? = nil, onSave: @escaping (SSHHost) -> Void = { _ in }) {
        self.model = model; self.host = host; self.draft = draft; self.onSave = onSave
        let initial = host ?? draft?.host
        let resolved = initial.flatMap { try? model.resolvedHost($0) } ?? initial
        _password = State(initialValue: draft?.secrets.password ?? "")
        _passphrase = State(initialValue: draft?.secrets.passphrase ?? "")
        _name = State(initialValue: initial?.name ?? "")
        _address = State(initialValue: initial?.address ?? "")
        _user = State(initialValue: resolved?.user ?? NSUserName())
        _port = State(initialValue: String(initial?.port ?? 22))
        _identity = State(initialValue: resolved?.identity ?? "")
        _group = State(initialValue: (initial?.group ?? defaultGroup ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        _fileProtocol = State(initialValue: initial?.fileProtocol ?? .sftp)
        _credentialID = State(initialValue: initial?.credentialID)
        switch initial?.upstream {
        case .host(let id): _upstream = State(initialValue: "host:" + id.uuidString); _proxyKind = State(initialValue: "ssh")
        case .proxy(let id): _upstream = State(initialValue: "proxy:" + id.uuidString); _proxyKind = State(initialValue: model.settings.proxies.first { $0.id == id }?.kind.rawValue ?? "none")
        case nil: break
        }
    }
    var body: some View {
        let _ = locale.identifier
        VStack(alignment: .leading, spacing: 14) {
            Text(T(host == nil ? "新建主机" : "编辑主机")).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    fieldLabel("名称")
                    HStack(spacing: 8) {
                        TextField(T("名称"), text: $name).labelsHidden().frame(minWidth: 120)
                            .accessibilityIdentifier("Termvia.Host.Name")
                        Text(T("分组")).foregroundStyle(.secondary).fixedSize()
                        NativePopUpPicker(selection: $group, options: [(value: "", title: model.defaultGroupTitle)] + model.groupNames.map { (value: $0, title: $0) }, label: "分组", identifier: "Termvia.Host.Group")
                            .frame(width: 130)
                    }
                }
                GridRow {
                    fieldLabel("地址")
                    HStack(spacing: 8) {
                        TextField(T("地址"), text: $address).labelsHidden()
                            .accessibilityIdentifier("Termvia.Host.Address")
                        Text(T("端口")).foregroundStyle(.secondary).fixedSize()
                        TextField(T("端口"), text: $port).labelsHidden().monospacedDigit().frame(width: 58)
                            .accessibilityIdentifier("Termvia.Host.Port")
                    }
                }
                GridRow {
                    fieldLabel("代理")
                    HStack(spacing: 8) {
                        NativePopUpPicker(selection: $proxyKind, options: [("none", T("无")), ("ssh", "SSH"), ("socks5", "SOCKS5"), ("http", "HTTP"), ("wireguard", "WireGuard")], label: "代理", identifier: "Termvia.Host.ProxyKind").frame(width: 95)
                        NativePopUpPicker(selection: $upstream, options: proxyOptions, label: "代理服务器", identifier: "Termvia.Host.Upstream").disabled(proxyKind == "none")
                        Button { var proxy = SSHProxy(); proxy.kind = SSHProxy.Kind(rawValue: proxyKind) ?? .socks5; proxyRequest = ProxyEditorRequest(proxy: proxy, creating: true) } label: { Image(systemName: "plus") }.disabled(proxyKind == "none" || proxyKind == "ssh").help(T("添加代理…"))
                    }
                }
                GridRow {
                    fieldLabel("登录信息")
                    HStack(spacing: 8) {
                        NativePopUpPicker(selection: $credentialID, options: [(value: Optional<UUID>.none, title: T("自定义"))] + model.credentials.map { (value: Optional($0.id), title: $0.name) }, label: "登录信息", identifier: "Termvia.Host.Login")
                            .frame(maxWidth: .infinity)
                        Button { editingCredential = nil; credentialEditor = true } label: { Image(systemName: "plus") }
                            .help(T("保存登录信息")).accessibilityLabel(T("保存登录信息"))
                        Button { editingCredential = selectedCredential; credentialEditor = true } label: { Image(systemName: "pencil") }
                            .disabled(selectedCredential == nil).help(T("编辑登录信息")).accessibilityLabel(T("编辑登录信息"))
                    }
                }
                GridRow {
                    fieldLabel("用户名")
                    TextField(T("用户名"), text: $user).labelsHidden().disabled(credentialID != nil)
                        .accessibilityIdentifier("Termvia.Host.User")
                }
                GridRow {
                    fieldLabel("私钥")
                    IdentityControls(identity: $identity, passphrase: $passphrase).disabled(credentialID != nil)
                }
                GridRow {
                    fieldLabel("密码")
                    SecureField(T("密码"), text: $password).labelsHidden().disabled(credentialID != nil)
                        .accessibilityIdentifier("Termvia.Host.Password")
                }
            }.textFieldStyle(.roundedBorder).controlSize(.small)
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            HStack {
                NativePopUpPicker(selection: $fileProtocol, options: SSHCommands.FileProtocol.allCases.map { (value: $0, title: $0.rawValue) }, label: "文件传输", identifier: "Termvia.Host.Protocol").frame(width: 95)
                Spacer()
                Button(T("取消")) { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("Termvia.Host.Cancel")
                Button(T(host == nil ? "添加" : "保存")) { save() }.keyboardShortcut(.defaultAction).confirmationButton().accessibilityIdentifier("Termvia.Host.Save")
            }
        }.padding(20).frame(width: 480)

#if TERMVIA_DIAGNOSTICS
        .background { if ProcessInfo.processInfo.arguments.contains("--launch-check") { ConnectionEditorCheckProbe(fileProtocol: fileProtocol.rawValue).frame(width: 0, height: 0).accessibilityHidden(true) } }
#endif

            .sheet(item: $proxyRequest) { request in ProxyEditor(model: model, request: request) { id in proxyKind = model.settings.proxies.first { $0.id == id }?.kind.rawValue ?? proxyKind; upstream = "proxy:" + id.uuidString } }
            .onChange(of: proxyKind) { _, _ in if !proxyOptions.contains(where: { $0.value == upstream }) { upstream = proxyOptions.first?.value ?? "" } }
            .task { if let host { loadSecrets(host) } }
            .onChange(of: credentialID) { _, _ in applyCredential() }
            .onChange(of: model.credentials) { _, _ in applyCredential() }
            .sheet(isPresented: $credentialEditor) {
                CredentialEditor(model: model, profile: editingCredential, user: user, method: method, identity: identity,
                                 secret: editingCredential == nil ? ((try? LoginSecrets(password: password, passphrase: passphrase).stored(method: method)) ?? "") : "") { id in
                    credentialID = model.credentials.contains { $0.id == id } ? id : nil; applyCredential()
                }
            }
    }
    private var proxyOptions: [(value: String, title: String)] {
        if proxyKind == "none" { return [("", T("无"))] }
        if proxyKind == "ssh" { return model.hosts.filter { $0.id != host?.id }.map { ("host:" + $0.id.uuidString, $0.name) } }
        return model.settings.proxies.filter { $0.kind.rawValue == proxyKind }.map { ("proxy:" + $0.id.uuidString, $0.name) }
    }
    private func fieldLabel(_ title: String) -> some View {
        Text(T(title)).foregroundStyle(.secondary).fixedSize().gridColumnAlignment(.trailing)
    }
    private func loadSecrets(_ host: SSHHost) {
        do { let values = try model.loginSecrets(for: host); password = values.password; passphrase = values.passphrase }
        catch { self.error = error.localizedDescription }
    }
    private func applyCredential() {
        if let selectedCredential {
            user = selectedCredential.user; identity = selectedCredential.identity
            do { let values = try model.loginSecrets(for: selectedCredential); password = values.password; passphrase = values.passphrase }
            catch { self.error = error.localizedDescription }
        } else { password = ""; passphrase = "" }
    }
    private func save() {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = host ?? draft?.host ?? SSHHost(name: "", address: "", user: "")
        if host == nil { updated.detectedSystem = nil; updated.detectedSystemVersion = nil }
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? address : name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.address = address.hasPrefix("[") && address.hasSuffix("]") ? String(address.dropFirst().dropLast()) : address
        updated.user = user; updated.port = Int(port) ?? 0
        updated.identity = (identity.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        updated.fileProtocol = fileProtocol; updated.authentication = method; updated.credentialID = credentialID
        updated.group = group.isEmpty ? nil : group
        let keepsImplicitLogin = credentialID == nil && updated.identity.isEmpty && password.isEmpty
            && host.map { $0.credentialID == nil && $0.identity.isEmpty && !model.hasSavedHostSecret($0.id) } == true
        if keepsImplicitLogin { updated.authentication = host?.authentication }
        if proxyKind == "none" { updated.upstream = nil }
        else if let id = UUID(uuidString: String(upstream.dropFirst(5))), upstream.hasPrefix("host:") { updated.upstream = .host(id) }
        else if let id = UUID(uuidString: String(upstream.dropFirst(6))), upstream.hasPrefix("proxy:") { updated.upstream = .proxy(id) }
        else { updated.upstream = nil }
        do {
            guard proxyKind == "none" || !upstream.isEmpty else { throw SSHError.invalid("请选择代理服务器") }
            guard keepsImplicitLogin || !updated.identity.isEmpty || !password.isEmpty else { throw SSHError.invalid("请输入密码或选择密钥") }
            let stored = try LoginSecrets(password: password, passphrase: passphrase).stored(method: method)
            try model.saveConnection(updated, secret: credentialID == nil ? stored : "")
            onSave(updated)
            password = ""; passphrase = ""; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
