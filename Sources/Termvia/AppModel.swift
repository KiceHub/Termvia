import AppKit
import SwiftUI
import SwiftTerm
import TermviaCore


struct Transfer: Identifiable {
    let id = UUID()
    let host: SSHHost
    let local: String
    let remote: String
    let upload: Bool
    let method: SSHCommands.FileProtocol
    var overwrite = false
    var directory = false
    var askConflicts = false
    let downloadTarget: DownloadTarget?
    var authentication: AuthenticationContext?
    var activity: TabActivity? = nil
    var destinationKey: String {
        if upload { return "remote:" + host.user + "@" + host.address.lowercased() + ":" + String(host.port) + ":" + Data(remote.utf8).base64EncodedString() }
        return "local:" + URL(fileURLWithPath: local).standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }
    var state = "排队中"
    var detail = ""
    func conflicts(with other: Self) -> Bool {
        guard upload == other.upload else { return false }
        if upload {
            guard host.user == other.host.user, host.address.lowercased() == other.host.address.lowercased(), host.port == other.host.port else { return false }
        }
        if destinationKey == other.destinationKey { return true }
        let path = upload ? remote : URL(fileURLWithPath: local).standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
        let otherPath = upload ? other.remote : URL(fileURLWithPath: other.local).standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
        return (directory && otherPath.hasPrefix(path + "/")) || (other.directory && path.hasPrefix(otherPath + "/"))
    }
}


enum WorkspaceFocusTarget { case terminal, hostSearch }
enum SettingsPage: String, CaseIterable { case general, terminal, connection, shortcuts, credentials, about }

@MainActor final class AppModel: ObservableObject {
    @Published private(set) var organization = HostOrganization()
    private var organizationReadFailure: String?
    @Published var newHostGroup: String?
    @Published var groupEditor: GroupEditorRequest?
    @Published private(set) var hosts: [SSHHost] = []
    @Published private(set) var credentials: [LoginCredential] = []
    let authenticationPrompts = AuthenticationPrompts()
    let fileConflicts = FileConflictPrompts()
    let quitShortcut = HoldToQuit()
    private var transientSecrets: [UUID: String] = [:]
    private let credentialStore: CredentialStore
    private let hostSecrets: any CredentialSecretStore
    private var credentialReadFailure: String?
    @Published var sessions: [Session] = [] { didSet { reconcileMonitoring() } }
    @Published var selected: UUID? {
        didSet {
            guard oldValue != selected else { return }
            if let previous = sessions.first(where: { $0.id == oldValue }), previous.initialDirectoryAttemptCompleted, !previous.fileMutationInProgress { previous.cancelListing() }
            switchWorkspace(to: active)
            focusTerminal()
        }
    }
    @Published private(set) var colorScheme: ColorScheme
    private weak var appearanceApplication: NSApplication?
    private var applicationAppearanceObservation: NSKeyValueObservation?
    @Published private(set) var focusRevision = 0
    @Published private(set) var focusTarget = WorkspaceFocusTarget.terminal
    var openSettings: (() -> Void)?
    @Published var localPath = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var localSelection: [URL] = []
    @Published var localSelectionSupportsTransfer = false
    @Published private(set) var localFilesRevision = 0
    private(set) var workspaceKey = "start"
    private var workspaces = HostWorkspaceStore()
    private var restoringWorkspace = false
    private var workspaceReadFailure: String?
    @Published var settingsPage = SettingsPage.general
    @Published var settings: AppSettings {
        didSet {
            let value = settings.validated()
            for session in sessions where !session.isStartPage { session.terminal.configure(value) }
            if oldValue.autoReconnect && !settings.autoReconnect { cancelAutomaticReconnects() }
            settingsSaveTask?.cancel()
            settingsSaveTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    self?.saveSettings(); self?.applyMonitorInterval()
                } catch {}
            }
        }
    }
    @Published var layout: WorkspaceLayout {
        didSet {
            Localization.preference = layout.language
            if oldValue.appearance != layout.appearance { synchronizeApplicationAppearance() }
            if !restoringWorkspace {
                if oldValue.monitorVisible != layout.monitorVisible { active?.sidebarVisible = layout.monitorVisible }
                if oldValue.panelVisible != layout.panelVisible {
                    for session in sessions where Self.workspaceKey(for: session) == workspaceKey {
                        setFileBrowserVisible(layout.panelVisible, for: session)
                    }
                }
                captureWorkspace(); reconcileMonitoring()
            }
            layoutSaveTask?.cancel()
            if oldValue.fontSize != layout.fontSize {
                for session in sessions where !session.isStartPage { session.terminal.font = .monospacedSystemFont(ofSize: layout.fontSize, weight: .regular) }
            }
            layoutSaveTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)); self?.saveLayout() } catch {}
            }
        }
    }
    @Published var transfers: [Transfer] = []
    var events: [String] { active?.activity.lines ?? [] }
    var activeTransfers: [Transfer] { guard let activity = active?.activity else { return [] }; return transfers.filter { $0.activity === activity } }
    @Published var error: String?
    var transferConfirmation: NSAlert?
    @Published var tabRenameTarget: Session?
    @Published var tabNameDraft = ""
    @Published var hostManagerPresented = false
    @Published var hostToEdit: SSHHost?
    @Published var hostTrustWarning: String?
    @Published var hostTrustToInspect: SSHHost?
    @Published var selectedHostID: UUID?
    @Published var hostSearch = ""
    @Published private(set) var hostSearchFocusRevision = 0
    let root: URL
    var commands: SSHCommands { SSHCommands(knownHosts: root.appendingPathComponent("known_hosts").path, useAskpass: true, suppressWarnings: settings.suppressOpenSSHWarnings, keepAliveInterval: settings.sshKeepAlive ? settings.validated().sshKeepAliveInterval : 0) }
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var fileJobs: [UUID: Task<Void, Never>] = [:]
    @Published private var filePlans = Set<UUID>()
    private var retiringSessions: [UUID: Session] = [:]
    private var layoutSaveTask: Task<Void, Never>?
    private var settingsSaveTask: Task<Void, Never>?
    private var monitorJobs: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var reconnectJobs: [UUID: Task<Void, Never>] = [:]
    private var restartJobs: [UUID: Task<Void, Never>] = [:]
    private var pausedTransfers = Set<UUID>()
    private var filePlanOwners: [UUID: TabActivity] = [:]
    var transferConfirmationOwner: TabActivity?
    private var settingsReadFailure: String?
    private var shuttingDown = false
    private var hostReadFailure: String?
    private let hostStore: ConnectionStore
    init(root: URL, secretStore: (any CredentialSecretStore)? = nil, hostSecretStore: (any CredentialSecretStore)? = nil) {
        hostSecrets = hostSecretStore ?? FileSecretStore(directory: root.appendingPathComponent("host-secrets", isDirectory: true))
        self.root = root
        credentialStore = CredentialStore(url: root.appendingPathComponent("credentials.json"), secrets: secretStore)
        hostStore = ConnectionStore(url: root.appendingPathComponent("hosts.json"))
        layout = WorkspaceLayout()
        settings = AppSettings()
        colorScheme = AppAppearance.scheme(for: NSApplication.shared.effectiveAppearance)
        let layoutFile = root.appendingPathComponent("workspace.json")
        if FileManager.default.fileExists(atPath: layoutFile.path) {
            do { layout = try JSONDecoder().decode(WorkspaceLayout.self, from: Data(contentsOf: layoutFile)).validated() }
            catch { self.error = T("无法读取工作区设置：%@", error.localizedDescription) }
        }
        Localization.preference = layout.language
        let settingsFile = root.appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: settingsFile.path) {
            do { settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: settingsFile)).validated() }
            catch { settingsReadFailure = error.localizedDescription; self.error = T("无法读取设置，已保留原文件：%@", error.localizedDescription) }
        }
        do { credentials = try credentialStore.load() }
        catch { credentialReadFailure = error.localizedDescription; self.error = T("无法读取登录信息：%@", error.localizedDescription) }
        let groupsURL = root.appendingPathComponent("host-groups.json")
        if FileManager.default.fileExists(atPath: groupsURL.path) {
            do { organization = try JSONDecoder().decode(HostOrganization.self, from: Data(contentsOf: groupsURL)) }
            catch { organizationReadFailure = error.localizedDescription; self.error = error.localizedDescription }
        }
        do { hosts = try hostStore.load() }
        catch { hostReadFailure = error.localizedDescription; self.error = T("无法读取主机配置：%@", error.localizedDescription) }
        let workspaceFile = root.appendingPathComponent("host-workspaces.json")
        if FileManager.default.fileExists(atPath: workspaceFile.path) {
            do { workspaces = try HostWorkspaceStore.decode(Data(contentsOf: workspaceFile), home: localPath) }
            catch { workspaceReadFailure = error.localizedDescription; self.error = T("无法读取主机布局，已保留原文件：%@", error.localizedDescription) }
        }
        if workspaces.states["start"] == nil {
            workspaces.states["start"] = HostWorkspace(layout: layout, localPath: localPath)
        }
        if let start = workspaces.states["start"] { layout = start.layout.applying(to: layout); localPath = start.localPath }
        colorScheme = AppAppearance.resolve(layout.appearance, inherited: NSApplication.shared.effectiveAppearance)
    }
    var preferredColorScheme: ColorScheme? {
        AppAppearance.override(for: layout.appearance).map { AppAppearance.scheme(for: $0) }
    }
    /// Called once by the App initializer, before SwiftUI creates any scene.
    /// Plain model instances do not change the process-wide AppKit appearance.
    func startApplicationAppearance(_ application: NSApplication? = nil) {
        let application = application ?? NSApplication.shared
        applicationAppearanceObservation?.invalidate()
        appearanceApplication = application
        applicationAppearanceObservation = application.observe(\.effectiveAppearance) { [weak self] application, _ in
            MainActor.assumeIsolated { self?.updateResolvedAppearance(application.effectiveAppearance) }
        }
        synchronizeApplicationAppearance()
    }
    private func synchronizeApplicationAppearance() {
        let application = appearanceApplication ?? NSApplication.shared
        if appearanceApplication != nil {
            let appearance = AppAppearance.override(for: layout.appearance)
            if application.appearance?.name != appearance?.name { application.appearance = appearance }
        }
        updateResolvedAppearance(application.effectiveAppearance)
    }
    func updateResolvedAppearance(_ appearance: NSAppearance) {
        // An inherited/window callback must never override an explicit choice.
        let scheme = AppAppearance.resolve(layout.appearance, inherited: appearanceApplication?.effectiveAppearance ?? appearance)
        if colorScheme != scheme { colorScheme = scheme }
    }
    var locale: Locale { Localization.locale(for: layout.language) }
    func saveLayout() {
        captureWorkspace()
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            func write(_ data: Data, name: String) throws {
                let url = root.appendingPathComponent(name)
                if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
            }
            try write(encoder.encode(layout.validated()), name: "workspace.json")
            if workspaceReadFailure == nil { try write(encoder.encode(workspaces), name: "host-workspaces.json") }
        }
        catch { self.error = T("无法保存工作区设置：%@", error.localizedDescription) }
    }
    func saveSettings() {
        guard settingsReadFailure == nil else { return }
        do { try JSONEncoder().encode(settings.validated()).write(to: root.appendingPathComponent("settings.json"), options: .atomic) }
        catch { self.error = T("无法保存设置：%@", error.localizedDescription) }
    }
    func focusTerminal() {
        if active?.isStartPage == true { focusTarget = .hostSearch; hostSearchFocusRevision += 1; return }
        if focusTarget != .terminal { focusTarget = .terminal }; focusRevision += 1
    }
    static func workspaceKey(for session: Session?) -> String {
        guard let session, !session.isStartPage else { return "start" }
        return session.host.map { "host:" + $0.id.uuidString } ?? "local"
    }
    func workspace(for key: String) -> HostWorkspace {
        workspaces.states[key] ?? workspaces.states["start"] ?? HostWorkspace(layout: layout, localPath: FileManager.default.homeDirectoryForCurrentUser.path)
    }
    func paneBinding<Value>(_ path: WritableKeyPath<WorkspaceLayout, Value>, workspace key: String) -> Binding<Value> {
        Binding(get: { self.workspaceKey == key ? self.layout[keyPath: path] : self.workspace(for: key).layout.applying(to: self.layout)[keyPath: path] }, set: { value in
            guard self.workspaceKey == key else { return }
            self.layout[keyPath: path] = value
        })
    }
    private func captureWorkspace() {
        var state = workspace(for: workspaceKey)
        state.layout = PaneLayout(layout.validated())
        workspaces.states[workspaceKey] = state
    }
    private func switchWorkspace(to session: Session?) {
        captureWorkspace()
        let key = Self.workspaceKey(for: session)
        restoringWorkspace = true
        if key != workspaceKey {
            workspaceKey = key
            let state = workspace(for: key)
            layout = state.layout.applying(to: layout); localPath = state.localPath; localSelection = []; localSelectionSupportsTransfer = false
        }
        layout.sidebarPage = session == nil || session?.isStartPage == true ? "hosts" : "monitor"
        if let session { layout.monitorVisible = session.sidebarVisible }
        if session?.isLocalTerminal == true { layout.panel = "文件" }
        restoringWorkspace = false
        if let session { setFileBrowserVisible(layout.panelVisible, for: session) }
        reconcileMonitoring()
    }
    func rememberLocalPath(_ path: String, workspace key: String) {
        var state = workspace(for: key); guard state.localPath != path else { return }
        state.localPath = path; workspaces.states[key] = state
        saveLayout()
    }
    func refreshLocalFiles() { localFilesRevision += 1 }
    private func rememberRemotePath(_ session: Session, _ path: String) {
        let key = Self.workspaceKey(for: session)
        var state = workspace(for: key); guard state.remotePath != path else { return }
        state.remotePath = path; workspaces.states[key] = state
        saveLayout()
    }
    func showHosts() {
        if let active, !active.isStartPage { newStartPage(); return }
        focusTarget = .hostSearch
        layout.monitorVisible = true
        layout.sidebarPage = "hosts"
        hostSearchFocusRevision += 1
    }
    func presentHostEditor(_ host: SSHHost? = nil, group: String? = nil) {
        guard !hostManagerPresented else { return }
        hostToEdit = host
        newHostGroup = group
        hostManagerPresented = true
    }
    func presentTabRename(_ session: Session) {
        guard !shuttingDown, sessions.contains(where: { $0 === session }) else { return }
        tabNameDraft = session.tabTitle; tabRenameTarget = session
    }
    func confirmTabRename() {
        guard let target = tabRenameTarget, sessions.contains(where: { $0 === target }) else { tabRenameTarget = nil; return }
        target.renameTab(tabNameDraft); tabRenameTarget = nil; focusTerminal()
    }
    func changeFont(_ delta: Double) { layout.fontSize = min(28, max(10, layout.fontSize + delta)) }
    func selectNext(_ direction: Int) {
        guard !sessions.isEmpty else { return }
        let index = sessions.firstIndex { $0.id == selected } ?? 0
        selected = sessions[(index + direction + sessions.count) % sessions.count].id
    }

    var active: Session? { sessions.first { $0.id == selected } }
    func fileProtocol(for session: Session) -> SSHCommands.FileProtocol {
        guard let host = session.host else { return .sftp }
        if let saved = hosts.first(where: { $0.id == host.id }) { return saved.fileProtocol ?? .sftp }
        return host.fileProtocol ?? .sftp
    }
    func log(_ message: String, activity: TabActivity? = nil) { (activity ?? active?.activity)?.append(message) }
    var displayHosts: [SSHHost] { hosts.map { (try? resolvedHost($0)) ?? $0 } }
    func resolvedHost(_ host: SSHHost) throws -> SSHHost {
        guard let id = host.credentialID else { return host }
        if let credentialReadFailure { throw SSHError.invalid(credentialReadFailure) }
        guard let profile = credentials.first(where: { $0.id == id }) else { throw SSHError.invalid("找不到已保存的登录信息，请重新选择") }
        return profile.applying(to: host)
    }
    func saveCredential(_ profile: LoginCredential, secret: CredentialSecretUpdate) throws {
        if let credentialReadFailure { throw SSHError.invalid(credentialReadFailure) }
        credentials = try credentialStore.save(profile, secret: secret)
        for context in authenticationContexts(for: profile.id) {
            switch secret {
            case .remove: context.replaceCachedSecret(nil)
            case .replace(let value) where context.host.user == profile.user && context.host.authentication == profile.authentication && context.host.identity == profile.identity: context.replaceCachedSecret(value)
            default: break
            }
        }
    }
    func credentialUseCount(_ id: UUID) -> Int { hosts.filter { $0.credentialID == id }.count }
    func deleteCredential(_ profile: LoginCredential) throws {
        if let credentialReadFailure { throw SSHError.invalid(credentialReadFailure) }
        guard credentialUseCount(profile.id) == 0 else { throw SSHError.invalid("请先解除主机对该登录信息的引用") }
        credentials = try credentialStore.delete(profile.id)
        for context in authenticationContexts(for: profile.id) { context.replaceCachedSecret(nil) }
    }
    private func authenticationContexts(for credentialID: UUID) -> [AuthenticationContext] {
        let contexts = (sessions + Array(retiringSessions.values)).compactMap(\.authentication) + transfers.compactMap(\.authentication)
        var seen = Set<ObjectIdentifier>()
        return contexts.filter { $0.host.credentialID == credentialID && seen.insert(ObjectIdentifier($0)).inserted }
    }
    func setTransientSecret(_ secret: String, for host: SSHHost) throws {
        try validateLoginSecret(secret)
        transientSecrets[host.id] = secret.isEmpty ? nil : secret
    }
    private func authentication(for host: SSHHost) throws -> AuthenticationContext {
        let secret = try (host.credentialID.map { try credentialStore.secrets.read($0) } ?? hostSecrets.read(host.id)) ?? transientSecrets[host.id]
        return AuthenticationContext(host: host, secret: secret, prompts: authenticationPrompts) { [weak self] value in self?.persistPromptSecret(value, for: host) }
    }
    private func sameLogin(_ a: SSHHost, _ b: SSHHost) -> Bool {
        a.address == b.address && a.port == b.port && a.user == b.user && a.authentication == b.authentication && a.identity == b.identity && a.credentialID == b.credentialID
    }
    private func persistPromptSecret(_ value: String, for host: SSHHost) {
        do {
            if let id = host.credentialID {
                guard let profile = credentials.first(where: { $0.id == id }), sameLogin(profile.applying(to: host), host) else { return }
            } else { guard let saved = hosts.first(where: { $0.id == host.id }), sameLogin(saved, host) else { return } }
            if let id = host.credentialID {
                try credentialStore.secrets.write(value, id: id)
                for context in authenticationContexts(for: id) where context.host.user == host.user && context.host.authentication == host.authentication && context.host.identity == host.identity { context.replaceCachedSecret(value) }
            } else { try hostSecrets.write(value, id: host.id) }
        } catch { self.error = error.localizedDescription }
    }
    func loginSecrets(for host: SSHHost) throws -> LoginSecrets {
        let resolved = try resolvedHost(host)
        let value = try host.credentialID.map { try credentialStore.secrets.read($0) } ?? hostSecrets.read(host.id)
        return LoginSecrets(stored: value, method: resolved.authentication ?? .automatic)
    }
    func loginSecrets(for profile: LoginCredential) throws -> LoginSecrets {
        LoginSecrets(stored: try credentialStore.secrets.read(profile.id), method: profile.authentication)
    }
    func hasSavedHostSecret(_ id: UUID) -> Bool { (try? hostSecrets.read(id)) != nil }
    func saveConnection(_ host: SSHHost, secret: String) throws {
        try validateLoginSecret(secret)
        let previousProtocol = hosts.first(where: { $0.id == host.id })?.fileProtocol ?? .sftp
        let before = try hostSecrets.read(host.id)
        let changed = hosts.first(where: { $0.id == host.id }).map { !sameLogin($0, host) } ?? false
        do {
            if host.credentialID != nil { try hostSecrets.delete(host.id) }
            else if !secret.isEmpty { try hostSecrets.write(secret, id: host.id) }
            else if changed { try hostSecrets.delete(host.id) }
            try save(host)
        } catch {
            if let before { try? hostSecrets.write(before, id: host.id) } else { try? hostSecrets.delete(host.id) }
            throw error
        }
        transientSecrets[host.id] = nil
        if previousProtocol != (host.fileProtocol ?? .sftp) {
            for session in sessions where session.host?.id == host.id && session.connected && !session.fileMutationInProgress {
                refreshDirectory(session)
            }
        }
    }
    func save(_ requestedHost: SSHHost) throws {
        var host = requestedHost
        if let existing = hosts.first(where: { $0.id == host.id }) {
            if existing.address == host.address && existing.port == host.port {
                if existing.detectedSystem != nil { host.detectedSystem = existing.detectedSystem; host.detectedSystemVersion = existing.detectedSystemVersion }
            } else { host.detectedSystem = nil; host.detectedSystemVersion = nil }
        }
        if let hostReadFailure { throw SSHError.invalid(T("原主机配置读取失败，已保留文件。请修复 hosts.json 并重新打开应用：%@", hostReadFailure)) }
        try host.validate()
        guard !hosts.contains(where: { $0.id != host.id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(host.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }) else { throw SSHError.invalid("主机名称已存在") }
        _ = try resolvedHost(host)
        var updated = hosts
        if let i = updated.firstIndex(where: { $0.id == host.id }) { updated[i] = host } else { updated.append(host) }
        try hostStore.save(updated)
        hosts = updated
        if host.credentialID != nil { transientSecrets[host.id] = nil }
        selectedHostID = host.id
    }
    var hostGroups: [HostGroup] { organization.sections(displayHosts, search: hostSearch) }
    var groupNames: [String] { organization.sections(hosts, search: "").compactMap(\.name) }
    var defaultGroupTitle: String { organization.defaultGroupName ?? T("默认分组") }
    func presentGroupEditor(_ group: HostGroup? = nil) { groupEditor = GroupEditorRequest(group: group) }
    func groupAppearance(_ group: String?) -> HostGroupAppearance { organization.appearances[HostGroupAppearance.key(for: group)] ?? HostGroupAppearance() }
    private func validatedGroupAppearance(_ appearance: HostGroupAppearance) throws -> HostGroupAppearance {
        let value = appearance.validated()
        guard value.symbol.utf8.count <= 128, NSImage(systemSymbolName: value.symbol, accessibilityDescription: nil)?.isValid == true else {
            throw SSHError.invalid(T("请选择有效的系统图标"))
        }
        return value
    }
    func setGroupAppearance(_ appearance: HostGroupAppearance, group: String?) throws {
        let appearance = try validatedGroupAppearance(appearance)
        guard organization.sections(hosts, search: "").contains(where: { $0.name == group }) else {
            throw SSHError.invalid(T("请选择有效的系统图标"))
        }
        var value = organization
        value.appearances[HostGroupAppearance.key(for: group)] = appearance == HostGroupAppearance() ? nil : appearance
        try saveOrganization(value)
    }
    func saveOrganization(_ value: HostOrganization) throws {
        if let organizationReadFailure { throw SSHError.invalid(organizationReadFailure) }
        try JSONEncoder().encode(value).write(to: root.appendingPathComponent("host-groups.json"), options: .atomic)
        organization = value
    }
    func createGroup(_ name: String) throws {
        try saveGroup(name: name, appearance: HostGroupAppearance(), editing: nil)
    }
    func saveGroup(name: String, appearance: HostGroupAppearance, editing group: HostGroup?) throws {
        if let organizationReadFailure { throw SSHError.invalid(organizationReadFailure) }
        if let hostReadFailure { throw SSHError.invalid(T("原主机配置读取失败，已保留文件。请修复 hosts.json 并重新打开应用：%@", hostReadFailure)) }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sections = organization.sections(hosts, search: "")
        if let group, group.name == nil {
            guard name == sections.first(where: { $0.id == group.id })?.title else { throw SSHError.invalid(T("默认分组名称不可修改")) }
        }
        guard !name.isEmpty, !sections.contains(where: { $0.id != group?.id && $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { throw SSHError.invalid(T("分组名称为空或已存在")) }
        if let group, !sections.contains(where: { $0.id == group.id }) { throw SSHError.invalid(T("分组已不存在")) }
        let appearance = try validatedGroupAppearance(appearance)
        var value = organization
        var updatedHosts = hosts
        let targetName: String?
        if let group {
            if let previous = group.name {
                targetName = name
                value.groups = sections.map { $0.name == previous ? name : ($0.name ?? "") }
                value.appearances[HostGroupAppearance.key(for: previous)] = nil
                updatedHosts = hosts.map { host in
                    var host = host
                    if host.group?.trimmingCharacters(in: .whitespacesAndNewlines) == previous { host.group = name }
                    return host
                }
            } else {
                // Preserve the default bucket's identity and existing title.
                targetName = nil
            }
        } else {
            targetName = name
            value.groups = sections.map { $0.name ?? "" } + [name]
        }
        value.appearances[HostGroupAppearance.key(for: targetName)] = appearance == HostGroupAppearance() ? nil : appearance
        if updatedHosts != hosts {
            // Both files must succeed before publishing. Restore the exact
            // host document and permissions if the organization write fails.
            let original = try Data(contentsOf: hostStore.url)
            let permissions = try FileManager.default.attributesOfItem(atPath: hostStore.url.path)[.posixPermissions]
            do { try hostStore.save(updatedHosts); try saveOrganization(value) }
            catch {
                let saveError = error
                do {
                    try original.write(to: hostStore.url, options: .atomic)
                    if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: hostStore.url.path) }
                } catch {
                    hostReadFailure = error.localizedDescription
                    throw SSHError.invalid(T("分组保存失败，无法恢复主机配置：%@", error.localizedDescription))
                }
                throw saveError
            }
            hosts = updatedHosts
        } else { try saveOrganization(value) }
        if let previous = group?.name, previous != targetName {
            layout.collapsedHostGroups = layout.collapsedHostGroups.map { $0 == "group:" + previous ? "group:" + name : $0 }
            if newHostGroup == previous { newHostGroup = name }
        }
        hostSearch = ""
    }
    /// Native List insertion positions include expanded hosts as well as group headers.
    func moveSidebarItem(_ token: String, into rows: [HostSidebarRow], at index: Int) -> Bool {
        guard (0...rows.count).contains(index) else { return false }
        let target = index < rows.count ? rows[index] : nil
        if token.hasPrefix("group:") {
            switch target {
            case .group(let group): return moveSidebarItem(token, group: group.name)
            case .host: return false // Group drops have no host-row insertion positions.
            case nil: return moveSidebarItem(token, group: nil, atEnd: true)
            }
        }
        switch target {
        case .group(let group):
            guard index > 0 || group.name != nil else { return false }
            let previous = rows.prefix(index).last?.group
            return moveSidebarItem(token, group: (previous ?? group).name)
        case .host(let host, let group): return moveSidebarItem(token, group: group.name, before: host.id)
        case nil: return moveSidebarItem(token, group: rows.last?.group.name)
        }
    }
    func moveSidebarItem(_ token: String, group: String?, before hostID: UUID? = nil, atEnd: Bool = false) -> Bool {
        do {
            if token.hasPrefix("group:") {
                let source = String(token.dropFirst(6))
                let target = group ?? ""
                let names = organization.sections(hosts, search: "").map { $0.name ?? "" }
                guard !source.isEmpty, (atEnd || (!target.isEmpty && source != target)), names.contains(source), names.contains(target) else { return false }
                var value = organization; value.groups = names.filter { $0 != source }
                value.groups.insert(source, at: atEnd ? value.groups.count : value.groups.firstIndex(of: target) ?? value.groups.count)
                try saveOrganization(value)
            } else if token.hasPrefix("host:"), let id = UUID(uuidString: String(token.dropFirst(5))), var host = hosts.first(where: { $0.id == id }) {
                guard id != hostID else { return false }
                host.group = group; try save(host)
                var value = organization
                value.hosts = organization.sections(hosts, search: "").flatMap(\.hosts).map(\.id).filter { $0 != id }
                value.hosts.insert(id, at: hostID.flatMap { value.hosts.firstIndex(of: $0) } ?? value.hosts.count)
                try saveOrganization(value)
            } else { return false }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func setHostIcon(_ icon: String?, host: SSHHost) {
        do { var value = hosts.first(where: { $0.id == host.id }) ?? host; value.customIcon = icon; try save(value) } catch { self.error = error.localizedDescription }
    }
    func deleteHost(_ host: SSHHost) throws {
        if let hostReadFailure { throw SSHError.invalid(T("原主机配置读取失败，已保留文件。请修复 hosts.json 并重新打开应用：%@", hostReadFailure)) }
        let updated = hosts.filter { $0.id != host.id }
        let previous = try hostSecrets.read(host.id)
        try hostSecrets.delete(host.id)
        do { try hostStore.save(updated) }
        catch { if let previous { try? hostSecrets.write(previous, id: host.id) }; throw error }; hosts = updated
        transientSecrets[host.id] = nil
        if selectedHostID == host.id { selectedHostID = nil }
    }
    func connect(_ host: SSHHost?) {
        guard !shuttingDown else { return }
        do {
            let session = try makeSession(host, activity: active?.isStartPage == true ? active?.activity : nil)
            if let active, active.isStartPage, let index = sessions.firstIndex(where: { $0.id == active.id }) {
                session.renameTab(active.customTabTitle ?? ""); if tabRenameTarget === active { tabRenameTarget = session }; active.stop(); sessions[index] = session
            } else { sessions.append(session) }
            selected = session.id
        } catch { self.error = error.localizedDescription }
    }
    func newStartPage() {
        guard !shuttingDown else { return }
        do {
            let page = try Session(host: nil, commands: commands, startPage: true)
            selectedHostID = nil
            sessions.append(page); selected = page.id
            showHosts()
        } catch { self.error = error.localizedDescription }
    }
    func tabIcon(for session: Session) -> String? {
        guard session.connected, let host = session.host else { return nil }
        let current = hosts.first { $0.id == host.id } ?? host
        return current.customIcon ?? current.detectedSystem ?? "server"
    }
    private func makeSession(_ host: SSHHost?, authenticationOverride: AuthenticationContext? = nil, monitorSelection: MonitorSelection? = nil, activity: TabActivity? = nil) throws -> Session {
        let host = try host.map { try resolvedHost($0) }
        let auth = try authenticationOverride ?? host.map { try authentication(for: $0) }
        let session = try Session(host: host, commands: commands, fontSize: layout.fontSize, authentication: auth, activity: activity)
        let key = host.map { "host:" + $0.id.uuidString } ?? "local"
        session.fileBrowserSuspended = !workspace(for: key).layout.panelVisible
        session.initialDirectoryAttemptCompleted = session.fileBrowserSuspended
        session.remotePath = workspace(for: key).remotePath
        session.sidebarVisible = workspace(for: key).layout.monitorVisible
        session.monitor.restoreSelection(monitorSelection ?? workspace(for: key).monitorSelection ?? MonitorSelection())
        session.monitor.selectionChanged = { [weak self] selection in
            guard let self, !self.shuttingDown else { return }
            var state = self.workspace(for: key); state.monitorSelection = selection.validated()
            self.workspaces.states[key] = state; self.saveLayout()
        }
        session.terminal.configure(settings.validated())
        session.prepareConnection = { [weak self] session in self?.prepare(session) }
        session.onExit = { [weak self] ended in
            self?.sessionEnded(ended)
        }
        session.onStart = { [weak self] started in self?.sessionStarted(started) }
        session.onDisconnect = { [weak self] ended in self?.pauseSessionOperations(ended) }
        session.onReconnect = { [weak self] ended in self?.reconnect(ended) }
        return session
    }
    private func sessionStarted(_ session: Session) {
        reconcileMonitoring()
        guard let host = session.host else { return }
        let method: String
        switch session.connectionSecurity?.authentication {
        case "publickey": method = T("密钥")
        case "password", "keyboard-interactive": method = T("密码")
        default: method = session.connectionSecurity?.authentication ?? T("已验证的认证")
        }
        let address = host.address.contains(":") ? "[\(host.address)]" : host.address
        log(T("远程连接 通过%@ 连接到 %@", method, "\(host.user)@\(address):\(host.port)"), activity: session.activity)
        if let algorithm = session.connectionSecurity?.keyExchange { log(T("密钥交换 %@", algorithm), activity: session.activity) }
    }
    func sessionEnded(_ ended: Session) {
        pauseSessionOperations(ended)
        retiringSessions[ended.id] = nil
        reconcileMonitoring()
        guard !ended.isStartPage, ended.host != nil else { return }
        let detail: String
        if case .failed(let message) = ended.phase { detail = message } else { detail = ended.status }
        log(T(ended.host == nil ? "本地终端 %@" : "远程连接 %@", detail), activity: ended.activity)
        guard !shuttingDown, settings.autoReconnect, !ended.wasStopped, ended.host != nil,
              sessions.contains(where: { $0 === ended }), reconnectJobs[ended.id] == nil else { return }
        let eligible: Bool
        switch ended.phase {
        case .exited(let code): eligible = code == 255 && ended.connectedAt != nil
        case .failed(let message): eligible = ended.isAutomaticReconnect && AppSettings.isTransientConnectionFailure(message)
        default: eligible = false
        }
        guard eligible else { return }
        if let connectedAt = ended.connectedAt, connectedAt.duration(to: .now) >= .seconds(30) { ended.reconnectAttempt = 0 }
        let attempt = ended.reconnectAttempt + 1
        guard attempt <= settings.validated().reconnectAttempts else { return }
        ended.reconnectPending = true
        let delay = settings.retryDelay(attempt: attempt)
        log(T("将在 %.0f 秒后自动重连 %@（%d）", delay, ended.title, attempt), activity: ended.activity)
        reconnectJobs[ended.id] = Task { [weak self, weak ended] in
            do { try await Task.sleep(for: .seconds(delay)); try Task.checkCancellation() } catch { return }
            guard let self, let ended else { return }
            defer { self.reconnectJobs[ended.id] = nil }
            ended.reconnectPending = false
            guard !self.shuttingDown, self.settings.autoReconnect, !ended.wasStopped, attempt <= self.settings.validated().reconnectAttempts,
                  self.sessions.contains(where: { $0 === ended }), let original = ended.host else { return }
            let host = self.hosts.first { $0.id == original.id } ?? original
            guard (try? self.resolvedHost(host)).map({ self.sameLogin($0, original) }) == true else { return }
            do {
                try await ended.restart(host: try self.resolvedHost(host), commands: self.commands, authentication: ended.authentication, automatic: true, attempt: attempt)
            } catch is CancellationError {} catch { self.log(error.localizedDescription, activity: ended.activity) }
        }
    }
    private func cancelAutomaticReconnects() {
        for job in reconnectJobs.values { job.cancel() }; reconnectJobs.removeAll()
        for session in sessions { session.reconnectPending = false }
        for session in sessions where session.isAutomaticReconnect && session.phase == .connecting { session.stop() }
    }
    private func prepare(_ session: Session) {
        guard !shuttingDown, let host = session.host else { return }
        let token = UUID()
        let task = Task {
            defer { fileJobs[token] = nil; session.connectionJob = nil }
            do {
                try Task.checkCancellation()
                let lease = try session.authentication?.lease(allowPrompts: !session.isAutomaticReconnect); defer { lease?.close() }
                let result: ConnectionVerification
                if let lease { result = try await lease.verifyConnection(host, commands: commands) }
                else { result = try await ConnectionVerifier.verify(host, commands: commands) }
                try Task.checkCancellation()
                guard result.status == 0 else {
                    if !session.isAutomaticReconnect && (result.output.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || result.output.contains("Offending")) {
                        let regex = try NSRegularExpression(pattern: "SHA256:[A-Za-z0-9+/=]+")
                        let fingerprints = regex.matches(in: result.output, range: NSRange(result.output.startIndex..., in: result.output)).compactMap { Range($0.range, in: result.output).map { String(result.output[$0]) } }
                        hostTrustWarning = T("服务器公钥已变更，连接已阻止。请核对指纹后再重新信任。") + "\n" + fingerprints.joined(separator: "\n")
                        hostTrustToInspect = host
                    }
                    session.connectionFailed(result.output); return
                }
                lease?.confirmAuthentication()
                session.connectionSecurity = result.security
                session.connectionPrepared()
                if session.connected {
                    refreshDirectory(session)
                    if (hosts.first(where: { $0.id == host.id }) ?? host).detectedSystemVersion != HostSystemIcon.detectionVersion {
                        @MainActor func probeSystem(_ command: String) async throws -> CommandResult {
                            let probe = try commands.execute(host, command: command)
                            let iconLease = try session.authentication?.lease(allowPrompts: false); defer { iconLease?.close() }
                            if let iconLease { return try await iconLease.run(probe) }
                            return try await ProcessRunner().run(probe)
                        }
                        var result = try await probeSystem(HostSystemIcon.probeCommand)
                        if result.status != 0 { result = try await probeSystem(HostSystemIcon.windowsProbeCommand) }
                        try Task.checkCancellation()
                        if result.status == 0 { session.detectedSystem = HostSystemIcon.detect(result.output) }
                        if result.status == 0, var current = hosts.first(where: { $0.id == host.id }), current.detectedSystemVersion != HostSystemIcon.detectionVersion {
                            current.detectedSystem = HostSystemIcon.detect(result.output); current.detectedSystemVersion = HostSystemIcon.detectionVersion
                            let updated = hosts.map { $0.id == current.id ? current : $0 }
                            try hostStore.save(updated); hosts = updated
                        }
                    }
                }
            } catch is CancellationError {} catch { if !session.connected { session.connectionFailed(error.localizedDescription) } else { log(error.localizedDescription, activity: session.activity) } }
        }
        session.connectionJob = task; fileJobs[token] = task
    }
    /// Monitor lifetime belongs to a live tab, independently of which view is attached.
    private func applyMonitorInterval() {
        guard !shuttingDown else { return }
        let interval = settings.validated().monitorInterval
        let affected = sessions.filter { $0.monitor.running && $0.monitor.interval != interval }
        guard !affected.isEmpty else { return }
        for session in affected {
            monitorJobs.removeValue(forKey: session.id)?.task.cancel(); session.monitor.stop()
        }
        reconcileMonitoring()
    }
    func reconcileMonitoring() {
        let eligible = Set(sessions.filter { !shuttingDown && $0.sidebarVisible && $0.readyForMonitoring }.map(\.id))
        for id in Array(monitorJobs.keys) where !eligible.contains(id) {
            monitorJobs.removeValue(forKey: id)?.task.cancel()
            sessions.first { $0.id == id }?.monitor.stop()
        }
        for session in sessions where eligible.contains(session.id) && monitorJobs[session.id] == nil {
            let token = UUID()
            let task = Task { [weak self, weak session] in
                guard !Task.isCancelled, let self, let session, session.readyForMonitoring, session.sidebarVisible, !self.shuttingDown else { return }
                await self.monitorSession(session)
                if self.monitorJobs[session.id]?.token == token { self.monitorJobs[session.id] = nil }
            }
            monitorJobs[session.id] = (token, task)
        }
    }
    func resample(_ session: Session) {
        monitorJobs.removeValue(forKey: session.id)?.task.cancel(); session.monitor.stop()
        reconcileMonitoring()
    }
    func monitorSession(_ session: Session) async {
        guard !Task.isCancelled, !shuttingDown, session.readyForMonitoring, session.sidebarVisible else { return }
        let token = UUID(), commands = commands
        let task = Task {
            defer { fileJobs[token] = nil }
            await session.monitor.run(host: session.host, authentication: session.authentication, commands: commands, interval: settings.validated().monitorInterval)
        }
        fileJobs[token] = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }
    func reconnect(_ session: Session) {
        guard !shuttingDown, sessions.contains(where: { $0 === session }), !session.isStartPage, restartJobs[session.id] == nil, !session.restarting else { return }
        reconnectJobs.removeValue(forKey: session.id)?.cancel(); session.reconnectPending = false
        do {
            let host = try session.host.map { original in try resolvedHost(hosts.first { $0.id == original.id } ?? original) }
            let context = try host.map { try authentication(for: $0) }
            session.stop()
            log(T("重新连接 %@", session.title), activity: session.activity)
            restartJobs[session.id] = Task {
                defer { restartJobs[session.id] = nil }
                do {
                    try await session.restart(host: host, commands: commands, authentication: context)
                } catch is CancellationError {} catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    func close(_ session: Session) {
        if tabRenameTarget === session { tabRenameTarget = nil }
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        reconnectJobs.removeValue(forKey: session.id)?.cancel()
        restartJobs.removeValue(forKey: session.id)?.cancel()
        session.stop(); if !session.isStartPage, session.terminal.process.running { retiringSessions[session.id] = session }; sessions.remove(at: index)
        for transfer in transfers where transfer.activity === session.activity { cancel(transfer.id) }
        session.authentication?.replaceCachedSecret(nil)
        if selected == session.id { selected = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id }
        session.activity.close()
        schedule()
        if sessions.isEmpty { newStartPage() }
    }
    static func remoteListingPath(_ path: String) -> String {
        if path == "~" || path == "~/" { return "." }
        if path.hasPrefix("~/") { return "./" + path.dropFirst(2) }
        return path
    }
    func setFileBrowserVisible(_ visible: Bool, for session: Session) {
        guard session.fileBrowserSuspended == visible else { return }
        session.fileBrowserSuspended = !visible
        if visible {
            resumeDirectoryIfNeeded(session)
        } else {
            session.cancelListing()
            session.remoteDirectory = nil; session.remoteSelection = []; session.listingError = nil
            session.directoryReadInterrupted = true
            // Monitoring must not wait for a file browser that is closed.
            session.initialDirectoryAttemptCompleted = true
        }
    }
    func showsLoad(for session: Session) -> Bool {
        session.detectedSystem != "windows"
    }
    var pendingTransfers: [Transfer] {
        transfers.filter { ["排队中", "传输中", "正在取消", "已暂停"].contains($0.state) }
    }
    var showsTransferButton: Bool { !layout.panelVisible && !pendingTransfers.isEmpty }
    func showPendingTransfers() {
        // Prefer the current tab's work, then bring the next task's owner forward.
        let task = pendingTransfers.first { $0.activity === active?.activity } ?? pendingTransfers.first
        if let owner = sessions.first(where: { $0.activity === task?.activity }) { selected = owner.id }
        layout.panel = "传输"; layout.panelVisible = true
    }
    func refreshDirectory(_ session: Session) {
        guard !session.fileBrowserSuspended, !session.fileMutationInProgress else { return }
        let path = fileProtocol(for: session) == .scp ? session.remotePath : Self.remoteListingPath(session.remotePath)
        remoteFiles(session, operations: [], path: path)
    }
    func resumeDirectoryIfNeeded(_ session: Session) {
        guard active?.id == session.id, !session.fileBrowserSuspended, session.directoryReadInterrupted, !session.listingBusy else { return }
        refreshDirectory(session)
    }
    private func pauseSessionOperations(_ session: Session) {
        monitorJobs.removeValue(forKey: session.id)?.task.cancel()
        for token in filePlans where filePlanOwners[token] === session.activity {
            fileJobs[token]?.cancel(); fileConflicts.cancel(scope: token)
        }
        for transfer in transfers where transfer.activity === session.activity && ["排队中", "传输中"].contains(transfer.state) {
            if shuttingDown { cancel(transfer.id); continue }
            pausedTransfers.insert(transfer.id)
            update(transfer.id, state: "已暂停")
            fileConflicts.cancel(scope: transfer.id); jobs[transfer.id]?.cancel()
        }
        if transferConfirmationOwner === session.activity, let alert = transferConfirmation {
            alert.window.sheetParent?.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        }
    }
    func canResumeTransfer(_ transfer: Transfer) -> Bool {
        transfer.state == "已暂停" && jobs[transfer.id] == nil && sessions.contains {
            $0.activity === transfer.activity && $0.connected && $0.phase == .running &&
            $0.host?.address == transfer.host.address && $0.host?.port == transfer.host.port && $0.host?.user == transfer.host.user
        }
    }
    func resumeTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }), canResumeTransfer(transfers[index]),
              let session = sessions.first(where: { $0.activity === transfers[index].activity }) else { return }
        // A resume retries the task, not an unsafe assumption about a partial
        // remote file. Existing folder/file conflicts are checked again.
        transfers[index].authentication = session.authentication
        transfers[index].askConflicts = true
        pausedTransfers.remove(id); update(id, state: "排队中"); schedule()
    }
    func mutateRemote(_ session: Session, operations: [SFTPOperation]) {
        guard !operations.isEmpty, !session.listingBusy, let directory = session.remoteDirectory else { return }
        remoteFiles(session, operations: operations, path: directory.path)
    }
    private func remoteFiles(_ session: Session, operations: [SFTPOperation], path: String) {
        guard !shuttingDown, session.connected, !session.fileBrowserSuspended else { return }
        session.cancelListing()
        guard let host = session.host else { return }
        session.directoryReadInterrupted = false
        let token = UUID(), authentication = session.authentication, method = fileProtocol(for: session)
        session.listingRequest = token; session.listingBusy = true; session.listingError = nil; session.fileMutationInProgress = !operations.isEmpty
        session.remoteDirectory = nil; session.remoteSelection = []
        session.listingJob = Task { [weak session] in
            defer {
                fileJobs[token] = nil
                if let session, session.listingRequest == token {
                    session.listingBusy = false; session.listingJob = nil; session.fileMutationInProgress = false
                    if session.connected { session.initialDirectoryAttemptCompleted = true; reconcileMonitoring() }
                    if !shuttingDown, session.connected, fileProtocol(for: session) != method { refreshDirectory(session) }
                }
            }
            do {
                try Task.checkCancellation()
                let lease = try authentication?.lease(); defer { lease?.close() }
                let operation = SFTPOperation.batch(operations + [.list(path)])
                let directory: RemoteDirectory?
                if method == .scp {
                    let invocation = try SSHFileClient.invocation(host, commands: commands, operation: operation)
                    if let lease { directory = try await lease.performSSHFiles(invocation) }
                    else { directory = try await SSHFileClient().perform(invocation) }
                } else {
                    let invocation = try commands.sftpSubsystem(host)
                    if let lease { directory = try await lease.performSFTP(operation, invocation: invocation) }
                    else { directory = try await SFTPClient().perform(operation, invocation: invocation) }
                }
                try Task.checkCancellation()
                guard let session, session.listingRequest == token, let directory else { return }
                lease?.confirmAuthentication()
                session.remoteDirectory = directory; session.remotePath = directory.path; session.remoteSelection = []
                rememberRemotePath(session, directory.path)
            } catch is CancellationError {} catch {
                guard let session, session.listingRequest == token else { return }
                session.listingError = error.localizedDescription
            }
        }
        fileJobs[token] = session.listingJob
    }
    func performLocalFileOperation(_ operation: @escaping @Sendable () throws -> Void) async throws {
        guard !shuttingDown else { throw CancellationError() }
        let token = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            fileJobs[token] = Task {
                defer { fileJobs[token] = nil }
                do {
                    try Task.checkCancellation()
                    // FileManager's synchronous operations cannot be interrupted
                    // safely. Finish an already-started operation before exit.
                    try await Task.detached { try operation() }.value
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func planFileTransfer(activity: TabActivity? = nil, _ operation: @escaping @MainActor (UUID) async throws -> Void) {
        guard !shuttingDown else { return }
        let token = UUID()
        filePlans.insert(token)
        filePlanOwners[token] = activity ?? active?.activity
        fileJobs[token] = Task {
            defer { fileJobs[token] = nil; filePlans.remove(token); filePlanOwners[token] = nil }
            do { try await operation(token) }
            catch is CancellationError {}
            catch { self.error = error.localizedDescription }
        }
    }
    func fileConflict(path: String, directory: Bool, scope: UUID, rename: URL? = nil) async throws -> FileConflictChoice {
        fileConflicts.window = authenticationPrompts.window
        return try await fileConflicts.ask(path: path, directory: directory, scope: scope, rename: rename)
    }
    func enqueue(local: String, remote: String, upload: Bool, method: SSHCommands.FileProtocol, host target: SSHHost? = nil, authentication context: AuthenticationContext? = nil, overwrite: Bool = false, directory: Bool = false, askConflicts: Bool = false, activity owner: TabActivity? = nil) {
        guard !shuttingDown else { return }
        guard let host = target ?? active?.host else { error = T("请先打开远程会话"); return }
        guard let owner = owner ?? active?.activity else { error = T("请先打开远程会话"); return }
        guard !owner.isClosed else { return }
        do {
            _ = try commands.transfer(host, local: local, remote: remote, upload: upload, method: method)
            let authentication: AuthenticationContext
            if let context { authentication = context }
            else if target == nil, let current = active?.authentication { authentication = current }
            else { authentication = try self.authentication(for: resolvedHost(host)) }
            let downloadTarget = try upload ? nil : DownloadTarget(destination: URL(fileURLWithPath: local))
            transfers.append(Transfer(host: host, local: downloadTarget?.destination.path ?? local, remote: remote, upload: upload, method: method, overwrite: overwrite, directory: directory, askConflicts: askConflicts, downloadTarget: downloadTarget, authentication: authentication, activity: owner)); schedule()
        } catch { self.error = error.localizedDescription }
    }
    private func schedule() {
        // Keep in-flight rows until cancellation reaps their process: they still
        // reserve their destination and a concurrency slot during teardown.
        transfers.removeAll { $0.activity?.isClosed == true && jobs[$0.id] == nil }
        guard !shuttingDown else { return }
        let activeTransfers = transfers.filter { jobs[$0.id] != nil }
        var destinations = activeTransfers
        var hostCounts = Dictionary(grouping: activeTransfers, by: { $0.host.id }).mapValues(\.count)
        for transfer in transfers where transfer.state == "排队中" {
            if let owner = sessions.first(where: { $0.activity === transfer.activity }), owner.host != nil, !owner.connected || owner.phase != .running {
                pausedTransfers.insert(transfer.id); update(transfer.id, state: "已暂停"); continue
            }
            guard jobs.count < 3 else { break }
            guard !destinations.contains(where: { $0.conflicts(with: transfer) }), hostCounts[transfer.host.id, default: 0] < 2 else { continue }
            destinations.append(transfer); hostCounts[transfer.host.id, default: 0] += 1
            update(transfer.id, state: "传输中")
            jobs[transfer.id] = Task {
                do {
                    try Task.checkCancellation()
                    if transfer.directory || (transfer.upload && transfer.askConflicts) {
                        let skipped = transfer.directory ? try await transferFolder(transfer) : try await transferUploadFile(transfer)
                        update(transfer.id, state: "成功")
                        if skipped > 0, let index = transfers.firstIndex(where: { $0.id == transfer.id }) { transfers[index].detail = T("已跳过 %d 项", skipped) }
                        if transfer.upload {
                            for session in sessions where session.host?.id == transfer.host.id && !session.fileMutationInProgress && Self.remoteListingPath(session.remotePath) == (transfer.remote as NSString).deletingLastPathComponent { refreshDirectory(session) }
                        } else { refreshLocalFiles() }
                        jobs[transfer.id] = nil; schedule()
                        return
                    }
                    let download = try transfer.downloadTarget.map { try DownloadStaging(target: $0, overwrite: transfer.overwrite) }
                    defer { download?.close() }
                    let lease = try transfer.authentication?.lease()
                    defer { lease?.close() }
                    var invocation = try commands.transfer(transfer.authentication?.host ?? transfer.host, local: download?.fileURL.path ?? transfer.local, remote: transfer.remote, upload: transfer.upload, method: transfer.method)
                    invocation.environment = lease?.environment ?? [:]
                    let result: CommandResult
                    if let lease { result = try await lease.run(invocation) } else { result = try await ProcessRunner().run(invocation) }
                    try Task.checkCancellation()
                    if result.status == 0 { lease?.confirmAuthentication(); try download?.commit() }
                    update(transfer.id, state: result.status == 0 ? "成功" : "失败", detail: result.output)
                    if result.status == 0 {
                        if transfer.upload {
                            for session in sessions where session.host?.id == transfer.host.id && !session.fileMutationInProgress && Self.remoteListingPath(session.remotePath) == (transfer.remote as NSString).deletingLastPathComponent { refreshDirectory(session) }
                        } else { refreshLocalFiles() }
                    }
                } catch is TransferSkipped { update(transfer.id, state: "已跳过") }
                catch is CancellationError { update(transfer.id, state: pausedTransfers.contains(transfer.id) ? "已暂停" : "已取消", detail: transfer.directory ? T("文件夹传输未完成，已完成的内容会保留。") : "") }
                catch { update(transfer.id, state: pausedTransfers.contains(transfer.id) ? "已暂停" : "失败", detail: error.localizedDescription + (transfer.directory && transfer.upload ? "\n" + T("文件夹上传未完成，远端可能保留部分内容。") : "")) }
                jobs[transfer.id] = nil; schedule()
            }
        }
    }
    private func update(_ id: UUID, state: String, detail: String = "") {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        let previousState = transfers[i].state
        transfers[i].state = state; transfers[i].detail = detail
        if previousState != state {
            let transfer = transfers[i]
            if let activity = transfer.activity {
                log("\(T(transfer.upload ? "上传" : "下载")) \(T(state)) \(transfer.host.name) \(transfer.local) ↔ \(transfer.remote)" + (state == "失败" && !detail.isEmpty ? " · " + detail : ""), activity: activity)
            }
        }
        if ["成功", "失败", "已取消", "已跳过"].contains(state) { transfers[i].authentication = nil }
    }
    func cancel(_ id: UUID) {
        guard let transfer = transfers.first(where: { $0.id == id }), ["排队中", "传输中", "已暂停"].contains(transfer.state) else { return }
        pausedTransfers.remove(id)
        if let task = jobs[id] { update(id, state: "正在取消"); task.cancel() }
        else { update(id, state: "已取消") }
    }
    var busy: Bool { !jobs.isEmpty || !filePlans.isEmpty || transfers.contains { ["排队中", "已暂停"].contains($0.state) } }
    var hasPendingFileOperations: Bool { !fileJobs.isEmpty }
    var busyRunningTransfers: Bool { !jobs.isEmpty }
    var hasLiveSessions: Bool { (sessions + Array(retiringSessions.values)).contains { !$0.isStartPage && $0.phase.isActive } }
    func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true; tabRenameTarget = nil; tabNameDraft = ""; quitShortcut.uninstall()
        applicationAppearanceObservation?.invalidate(); applicationAppearanceObservation = nil; appearanceApplication = nil
        if let alert = transferConfirmation { alert.window.sheetParent?.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
        authenticationPrompts.cancelAll(); transientSecrets.removeAll()
        fileConflicts.cancelAll()
        layoutSaveTask?.cancel(); settingsSaveTask?.cancel(); saveLayout(); saveSettings(); cancelAutomaticReconnects()
        for task in restartJobs.values { task.cancel() }; restartJobs.removeAll()
        pausedTransfers.removeAll()
        for transfer in transfers where ["排队中", "已暂停"].contains(transfer.state) { update(transfer.id, state: "已取消") }
        for value in monitorJobs.values { value.task.cancel() }; monitorJobs.removeAll()
        for task in jobs.values { task.cancel() }
        for task in fileJobs.values { task.cancel() }
        for session in sessions + Array(retiringSessions.values) { session.stop() }
    }
    func finishShutdown() async {
        // Cancellation can finish a parent before a newly registered child is
        // visible in its first snapshot. Drain until all channels have reaped.
        repeat {
            let pending = Array(jobs.values) + Array(fileJobs.values)
            for task in pending { await task.value }
            for session in sessions + Array(retiringSessions.values) { await session.monitor.stopAndWait() }
            await Task.yield()
        } while !jobs.isEmpty || !fileJobs.isEmpty
        for _ in 0..<150 {
            if (sessions + Array(retiringSessions.values)).allSatisfy({ $0.isStartPage || !$0.terminal.process.running }) { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
