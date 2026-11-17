import AppKit
import SwiftUI
import TermviaCore

extension AppModel {
    func swapPanes(_ first: UUID, _ second: UUID) {
        guard first != second, let tab = sessions.first(where: { splitTrees[$0.id]?.leaves.contains(first) == true && splitTrees[$0.id]?.leaves.contains(second) == true }), let tree = splitTrees[tab.id] else { return }
        splitTrees[tab.id] = tree.swapping(first, second)
    }
    func tabTerminal(_ tab: Session) -> Session {
        splitFocus[tab.id].flatMap { session($0) } ?? tab
    }
    var focusedTerminal: Session? {
        guard let selected else { return nil }
        let id = splitFocus[selected] ?? selected
        return allSessions.first { $0.id == id }
    }
    var allSessions: [Session] { sessions + Array(splitSessions.values) }
    var activeSplitTree: TerminalSplitTree? { selected.flatMap { splitTrees[$0] } }
    func auxiliaryOwner(for candidate: Session) -> Session {
        guard let host = candidate.host, let tab = sessions.first(where: { splitTrees[$0.id]?.leaves.contains(candidate.id) == true }), let tree = splitTrees[tab.id] else { return candidate }
        if let id = splitAuxiliaryOwners[tab.id]?[host.id], tree.leaves.contains(id), let owner = session(id), owner.connected { return owner }
        guard let owner = tree.leaves.compactMap({ session($0) }).first(where: { $0.host?.id == host.id && $0.connected }) else { return candidate }
        splitAuxiliaryOwners[tab.id, default: [:]][host.id] = owner.id
        if owner.remoteDirectory == nil && owner.initialDirectoryAttemptCompleted { owner.directoryReadInterrupted = true }
        return owner
    }
    func isAuxiliaryOwner(_ candidate: Session) -> Bool { auxiliaryOwner(for: candidate).id == candidate.id }
    func isSplitSession(_ session: Session) -> Bool { splitTrees.values.contains { $0.leaves.contains(session.id) } || splitTrees[session.id] != nil }
    func session(_ id: UUID) -> Session? { allSessions.first { $0.id == id } }
    func split(_ target: Session, host: SSHHost?, sideBySide: Bool) {
        guard !target.isStartPage, let tab = sessions.first(where: { $0.id == target.id || splitTrees[$0.id]?.leaves.contains(target.id) == true }) else { return }
        do {
            let child = try makeSession(host)
            child.sidebarVisible = layout.monitorVisible
            captureCurrentWorkspace(); seedSplitWorkspace(tab.id)
            var tree = splitTrees[tab.id] ?? .leaf(tab.id)
            let focus = splitFocus[tab.id] ?? target.id
            tree = tree.adding(child.id, beside: focus, sideBySide: sideBySide)
            splitSessions[child.id] = child; splitTrees[tab.id] = tree
            selected = tab.id; focusPane(child)
        } catch { self.error = error.localizedDescription }
    }
    func focusPane(_ session: Session) {
        guard let tab = sessions.first(where: { $0.id == session.id || splitTrees[$0.id]?.leaves.contains(session.id) == true }) else { return }
        let oldHost = active?.host?.id
        splitFocus[tab.id] = session.id
        if selected != tab.id { selected = tab.id }
        if oldHost != active?.host?.id || workspaceKey != "split:" + tab.id.uuidString { activateFocusedWorkspace() }
        focusTerminal()
    }
    func removePane(_ session: Session) {
        guard let tab = sessions.first(where: { splitTrees[$0.id]?.leaves.contains(session.id) == true }), let tree = splitTrees[tab.id] else { close(session); return }
        guard let remaining = tree.removing(session.id), let next = remaining.leaves.first else { close(tab); return }
        retirePane(session)
        splitTrees[tab.id] = remaining
        if session.id != tab.id { splitSessions[session.id] = nil }
        splitFocus[tab.id] = next
        activateFocusedWorkspace(); reconcileMonitoring(); if let active { resumeDirectoryIfNeeded(active) }; focusTerminal()
    }
    func splitActions(for session: Session) -> [NativeSessionTab.Action] {
        guard !session.isStartPage else { return [] }
        let target = splitTrees[session.id] != nil ? (splitFocus[session.id].flatMap { self.session($0) } ?? session) : session
        let directions = [(false, "上下"), (true, "左右")].map { sideBySide, label -> NativeSessionTab.Action in
            var hosts: [NativeSessionTab.Action] = [.init(T("本主机") + " · " + target.title) { [weak self] in self?.split(target, host: target.host, sideBySide: sideBySide) }]
            if target.host != nil { hosts.append(.init(T("本地终端")) { [weak self] in self?.split(target, host: nil, sideBySide: sideBySide) }) }
            hosts.append(.separator)
            hosts += organization.sections(displayHosts, search: "").map { group in
                .init(group.title, children: group.hosts.map { host in .init(host.name) { [weak self] in self?.split(target, host: host, sideBySide: sideBySide) } })
            }
            return .init(T(label), children: hosts)
        }
        let actions: [NativeSessionTab.Action] = [.init(T("窗口拆分"), children: directions)]
        return actions
    }
}
struct SplitRequest: Identifiable { let id = UUID(); let session: Session; let sideBySide: Bool }
struct SplitHostPicker: View {
    @ObservedObject var model: AppModel
    let request: SplitRequest
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading) {
            Text(T("选择主机…")).font(.headline)
            List {
                Button(T("本地终端")) { model.split(request.session, host: nil, sideBySide: request.sideBySide); dismiss() }
                ForEach(model.displayHosts) { host in
                    Button(host.name + " · " + host.address) { model.split(request.session, host: host, sideBySide: request.sideBySide); dismiss() }
                }
            }.listStyle(.inset)
            HStack { Spacer(); Button(T("取消")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(16).frame(width: 420, height: 360)
    }
}
struct SplitTerminalWorkspace: NSViewRepresentable {
    @ObservedObject var model: AppModel
    let tree: TerminalSplitTree
    func makeNSView(context: Context) -> NativeTerminalSplits { NativeTerminalSplits() }
    func updateNSView(_ view: NativeTerminalSplits, context: Context) { view.update(model: model, tree: tree) }
}

@MainActor final class SplitNativeMenu: NSObject {
    static let shared = SplitNativeMenu()
    static func make(_ actions: [NativeSessionTab.Action]) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for action in actions {
            if !action.children.isEmpty { let item = NSMenuItem(title: action.title, action: nil, keyEquivalent: ""); item.submenu = make(action.children); menu.addItem(item); continue }
            if action.perform == nil { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: action.title, action: #selector(invoke(_:)), keyEquivalent: "")
            item.target = shared; item.representedObject = action; item.isEnabled = action.enabled; menu.addItem(item)
        }
        return menu
    }
    @objc private func invoke(_ sender: NSMenuItem) { if let action = sender.representedObject as? NativeSessionTab.Action { RunLoop.main.perform(inModes: [.default]) { action.perform?() } } }
}
