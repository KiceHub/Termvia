import AppKit
import CryptoKit
import SwiftUI
import TermviaCore

struct ProxyEditorRequest: Identifiable {
    let id = UUID()
    var proxy: SSHProxy
    var creating = false
}
struct ProxySettings: View {
    @ObservedObject var model: AppModel
    @State private var request: ProxyEditorRequest?
    @State private var search = ""
    private var matches: [SSHProxy] { model.settings.proxies.filter { search.isEmpty || ($0.name + " " + $0.kind.rawValue + " " + $0.address).localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                TextField(T("搜索代理"), text: $search).textFieldStyle(.roundedBorder)
                Button { request = ProxyEditorRequest(proxy: SSHProxy(), creating: true) } label: { Image(systemName: "plus") }.help(T("添加代理…")).accessibilityIdentifier("Termvia.Proxy.Add")
            }
            List(matches) { proxy in
                HStack(spacing: 8) {
                    Text(proxy.name).lineLimit(1)
                    Text(proxy.kind.rawValue.uppercased()).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 2).background(.quaternary, in: Capsule())
                    Spacer()
                    HStack(spacing: 6) {
                        Button { request = ProxyEditorRequest(proxy: proxy) } label: { Image(systemName: "pencil").frame(width: 16, height: 16) }.help(T("编辑")).accessibilityLabel(T("编辑")).accessibilityIdentifier("Termvia.Proxy.Edit." + proxy.id.uuidString)
                        Button(role: .destructive) { remove(proxy) } label: { Image(systemName: "trash").frame(width: 16, height: 16) }.help(T("删除")).accessibilityLabel(T("删除")).accessibilityIdentifier("Termvia.Proxy.Delete." + proxy.id.uuidString)
                    }.buttonStyle(.bordered).controlSize(.small)
                }.padding(.vertical, 2)
            }.listStyle(.inset)
        }.padding(16).sheet(item: $request) { ProxyEditor(model: model, request: $0) }
    }
    private func remove(_ proxy: SSHProxy) {
        do { try model.deleteProxy(proxy) } catch { model.error = error.localizedDescription }
    }
}
struct WireGuardSecrets: Codable { var privateKey: String; var presharedKey: String }
struct ProxyEditor: View {
    @ObservedObject var model: AppModel
    let completion: ((UUID) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var proxy: SSHProxy
    @State private var port: String
    @State private var password = ""
    @State private var privateKey = ""
    @State private var showPrivateKey = false
    @State private var presharedKey = ""
    @State private var peerKey = ""
    @State private var localIP = ""
    @State private var mtu = ""
    @State private var error: String?
    private let creating: Bool
    init(model: AppModel, request: ProxyEditorRequest, completion: ((UUID) -> Void)? = nil) {
        self.model = model; self.completion = completion; creating = request.creating
        var value = request.proxy
        if request.creating { value.address = ""; value.port = 0 }
        _proxy = State(initialValue: value); _port = State(initialValue: request.creating ? "" : String(value.port))
        _peerKey = State(initialValue: value.wireGuard?.peerPublicKey ?? "")
        _localIP = State(initialValue: value.wireGuard?.localIP ?? "")
        _mtu = State(initialValue: value.wireGuard.map { String($0.mtu) } ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(T("代理服务器")).font(.headline)
            Form {
                TextField(T("备注"), text: $proxy.name)
                Picker(T("类型"), selection: $proxy.kind) { ForEach(SSHProxy.Kind.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) } }
                TextField(T(proxy.kind == .wireguard ? "对端 IP" : "地址"), text: $proxy.address)
                TextField(T("端口"), text: $port)
                if proxy.kind == .wireguard {
                    HStack(spacing: 6) {
                        Group {
                            if showPrivateKey { TextField(T("私钥"), text: $privateKey).accessibilityIdentifier("Termvia.WireGuard.PrivateKey.Visible") }
                            else { SecureField(T("私钥"), text: $privateKey).accessibilityIdentifier("Termvia.WireGuard.PrivateKey.Hidden") }
                        }
                        Button { showPrivateKey.toggle() } label: { Image(systemName: showPrivateKey ? "eye.slash" : "eye") }
                            .help(T(showPrivateKey ? "隐藏私钥" : "查看私钥")).accessibilityLabel(T(showPrivateKey ? "隐藏私钥" : "查看私钥")).accessibilityIdentifier("Termvia.WireGuard.PrivateKey.Toggle")
                        Button(T("生成")) { privateKey = Curve25519.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString() }
                    }
                    if let key = Data(base64Encoded: privateKey), let value = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: key) {
                        LabeledContent(T("本机公钥")) { Text(value.publicKey.rawRepresentation.base64EncodedString()).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                    TextField(T("Peer 公钥"), text: $peerKey)
                    SecureField(T("预共享密钥"), text: $presharedKey)
                    TextField(T("本机 IP"), text: $localIP)
                    TextField("MTU", text: $mtu, prompt: Text("1420"))
                } else {
                    TextField(T("用户名"), text: $proxy.username)
                    SecureField(T("密码"), text: $password)
                }
            }.textFieldStyle(.roundedBorder)
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button(T("取消")) { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("Termvia.Proxy.Cancel"); Button(T("保存")) { save() }.keyboardShortcut(.defaultAction).confirmationButton() }
        }.padding(20).frame(width: 500).task {
            guard !creating else { return }
            do {
                let value = try model.proxySecret(proxy.id) ?? ""
                if proxy.kind == .wireguard, let secrets = try? JSONDecoder().decode(WireGuardSecrets.self, from: Data(value.utf8)) { privateKey = secrets.privateKey; presharedKey = secrets.presharedKey }
                else { password = value }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func save() {
        do {
            proxy.port = Int(port) ?? 0; proxy.name = proxy.name.trimmingCharacters(in: .whitespacesAndNewlines)
            proxy.address = proxy.address.trimmingCharacters(in: .whitespacesAndNewlines)
            var secret = password
            if proxy.kind == .wireguard {
                guard Data(base64Encoded: privateKey)?.count == 32, presharedKey.isEmpty || Data(base64Encoded: presharedKey)?.count == 32 else { throw SSHError.invalid("WireGuard 密钥必须为 Base64 编码的 32 字节密钥") }
                var config = SSHProxy.WireGuard(); config.peerPublicKey = peerKey; config.localIP = localIP; config.mtu = mtu.isEmpty ? 1420 : Int(mtu) ?? 0
                proxy.wireGuard = config; proxy.username = ""
                secret = String(decoding: try JSONEncoder().encode(WireGuardSecrets(privateKey: privateKey, presharedKey: presharedKey)), as: UTF8.self)
            } else { proxy.wireGuard = nil; guard password.utf8.count <= 255 else { throw SSHError.invalid("代理密码过长") } }
            try model.saveProxy(proxy, secret: secret); completion?(proxy.id); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
