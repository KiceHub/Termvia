import AppKit
import SwiftUI
import TermviaCore

struct WorkspaceSidebar: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: AppModel
    var staticPreview = false
    var previewSession: Session?
    var body: some View {
        let _ = locale.identifier
        Group {
            if (staticPreview ? previewSession : model.active).map({ $0.isStartPage }) ?? true {
                HostSidebar(model: model, staticPreview: staticPreview).padding(.top, 10)
            } else {
                MonitorSidebar(session: previewSession ?? model.active, sessionCount: staticPreview ? (previewSession == nil ? 0 : 2) : model.sessions.count, scrollable: !staticPreview, model: model)
            }
        }.frame(minWidth: 190, maxWidth: .infinity, maxHeight: .infinity)
#if TERMVIA_DIAGNOSTICS
        .background(AppearanceCheckProbe(role: "sidebar"))
#endif

    }
}

enum HostSidebarRow: Identifiable {
    case group(HostGroup), host(SSHHost, HostGroup)
    var id: String {
        switch self { case .group(let group): return group.id; case .host(let host, _): return "host:" + host.id.uuidString }
    }
    var group: HostGroup {
        switch self { case .group(let group), .host(_, let group): return group }
    }
}

struct HostSidebar: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: AppModel
    var staticPreview = false
    @State private var deleting: SSHHost?
    @State private var searchCollapsedGroups = Set<String>()
    private var groups: [HostGroup] { model.hostGroups }
    private var rows: [HostSidebarRow] {
        groups.flatMap { group in
            [.group(group)] + (expansion(group.id).wrappedValue ? group.hosts.map { .host($0, group) } : [])
        }
    }
    var body: some View {
        let _ = locale.identifier
        VStack(spacing: 0) {
            if staticPreview {
#if TERMVIA_DIAGNOSTICS
                Image(nsImage: NativeControlPreview.hostSearch()).padding(.horizontal, 10).padding(.bottom, 6)
#endif
                previewTree
            } else {
                NativeSearchField(text: $model.hostSearch, focusRevision: model.hostSearchFocusRevision).frame(height: 24).padding(.horizontal, 10).padding(.bottom, 6)
                HostGroupDropArea(rows: rows, move: { source, before in
                    model.moveSidebarItem("group:" + source, group: before, atEnd: before == nil)
                }, moveHost: { id, index in
                    model.moveSidebarItem("host:" + id.uuidString, into: rows, at: index)
                }) {
                    List(selection: $model.selectedHostID) {
                        ForEach(rows) { row in
                            Group {
                                switch row {
                                case .group(let group):
                                    HStack(spacing: 8) {
                                        HostGroupTitle(group: group, appearance: model.groupAppearance(group.name), expanded: expansion(group.id).wrappedValue) {
                                            expansion(group.id).wrappedValue.toggle()
                                        }.frame(maxWidth: .infinity, minHeight: 24)
                                        Button { model.presentHostEditor(group: group.name) } label: { Image(systemName: "plus") }
                                            .buttonStyle(.borderless).frame(width: 20, height: 24).help(T("新增主机"))
                                            .accessibilityIdentifier("Termvia.HostGroup.Add." + group.id)
                                    }
                                    .contextMenu {
                                        Button(T("新增主机")) { model.presentHostEditor(group: group.name) }
                                        Button(T("编辑分组…")) { model.presentGroupEditor(group) }
                                        Button(T("新建分组…")) { model.presentGroupEditor() }
                                    }
                                case .host(let host, _):
                                    hostRow(host)
                                }
                            }.itemProvider {
                                if case .host(let host, _) = row { return NSItemProvider(object: ("host:" + host.id.uuidString) as NSString) }
                                return nil
                            }
                        }
                    }.listStyle(.sidebar).scrollContentBackground(.hidden)
                        .background(HostListBlankSelection { model.selectedHostID = nil })
                        .contextMenu(forSelectionType: UUID.self) { ids in
                            if let host = model.hosts.first(where: { ids.contains($0.id) }) {
                                Button(T("连接")) { model.connect(host) }
                                Button(T("编辑…")) { model.presentHostEditor(host) }
                                Menu(T("主机图标")) {
                                    Button(T("自动")) { model.setHostIcon(nil, host: host) }
                                    ForEach(HostSystemIcon.allCases) { icon in
                                        Button { model.setHostIcon(icon.rawValue, host: host) } label: { Label { Text(icon.title) } icon: { HostIcon(icon: icon.rawValue) } }
                                    }
                                }
                                Button(T("主机指纹…")) { model.hostTrustToInspect = host }
                                Divider()
                                Button(T("删除…"), role: .destructive) { deleting = host }
                            } else {
                                Button(T("新增主机")) { model.presentHostEditor() }
                                Button(T("新建分组…")) { model.presentGroupEditor() }
                            }
                        } primaryAction: { ids in
                            if ids.count == 1, let host = model.hosts.first(where: { ids.contains($0.id) }) { model.connect(host) }
                        }
                        .overlay {
                            if groups.isEmpty { EmptyPane(symbol: "server.rack", title: model.hosts.isEmpty ? "无主机" : "没有匹配的主机", detail: "") }
                        }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: model.hostSearch) { _, _ in searchCollapsedGroups = [] }
        .alert(T("删除此主机配置？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(T("删除"), role: .destructive) {
                if let host = deleting {
                    do { try model.deleteHost(host) } catch { model.error = error.localizedDescription }
                }
                deleting = nil
            }
            Button(T("取消"), role: .cancel) { deleting = nil }
        } message: { Text(T("删除配置后，已打开的终端和传输继续运行；已保存的主机指纹保留。")) }
    }
    private func hostRow(_ host: SSHHost) -> some View {
        SavedHostRow(host: host).padding(.leading, 14).tag(host.id)
            .listRowBackground(HostSelectionOutline(selected: model.selectedHostID == host.id))
    }
    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: {
            model.hostSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? !model.layout.collapsedHostGroups.contains(id) : !searchCollapsedGroups.contains(id)
        }, set: { expanded in
            if !model.hostSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if expanded { searchCollapsedGroups.remove(id) } else { searchCollapsedGroups.insert(id) }
                return
            }
            var collapsed = Set(model.layout.collapsedHostGroups)
            if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
            model.layout.collapsedHostGroups = collapsed.sorted()
        })
    }
    private var previewTree: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(groups) { group in
                HStack(spacing: HostGroupTitleGrid.spacing) {
                    GroupAppearanceIcon(appearance: model.groupAppearance(group.name))
                        .frame(width: HostGroupTitleGrid.iconColumn)
                    Text(group.title).font(.callout).lineLimit(1)
                }.foregroundStyle(.secondary).padding(.top, 8)
                ForEach(group.hosts) { host in
                    SavedHostRow(host: host).padding(.leading, 14).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                        .overlay { if model.selectedHostID == host.id { RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1) } }
                }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SavedHostRow: View {
    let host: SSHHost
    var selected = false
    var body: some View {
        Label { Text(host.name).font(.callout).lineLimit(1).foregroundStyle(Color(nsColor: .labelColor)) } icon: {
            HostIcon(icon: host.customIcon ?? host.detectedSystem ?? "server", selected: selected)
        }.help("\(host.user)@\(host.address.contains(":") ? "[" + host.address + "]" : host.address)")
    }
}

/// Keep native List selection and input routing; use the same inset accent
/// outline as its context-menu target instead of the filled selection layer.
private struct HostSelectionOutline: View {
    let selected: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color(nsColor: .selectedContentBackgroundColor), lineWidth: 2)
            .opacity(selected ? 1 : 0)
            .padding(.horizontal, 12).padding(.vertical, 1.5)
    }
}
