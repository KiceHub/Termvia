import AppKit
import SwiftUI
import TermviaCore

enum GroupAppearanceColor {
    static let presets: [(name: String, hex: String)] = [
        ("红色", "D65B60"), ("橙色", "C98432"), ("黄色", "B09B36"), ("绿色", "41986A"), ("青色", "279A9D"),
        ("蓝色", HostGroupAppearance.defaultColorHex), ("紫色", "9766C1"), ("粉色", "C96695"), ("棕色", "9D7962"), ("灰色", "80858C")
    ]
    static func native(_ hex: String) -> NSColor {
        let rgb = UInt32(hex, radix: 16) ?? 0
        return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 1)
    }
}

struct GroupAppearanceIcon: View {
    let appearance: HostGroupAppearance
    private var symbol: String { appearance.symbol.utf8.count > 128 || NSImage(systemSymbolName: appearance.symbol, accessibilityDescription: nil) == nil ? "folder" : appearance.symbol }
    var body: some View {
        Image(systemName: symbol).foregroundStyle(Color(nsColor: GroupAppearanceColor.native(appearance.resolvedColorHex)))
    }
}

struct GroupEditorRequest: Identifiable {
    let id = UUID()
    let group: HostGroup?
}

@MainActor struct GroupEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let group: HostGroup?
    @State private var name: String
    @State private var appearance: HostGroupAppearance
    @State private var error: String?
    init(model: AppModel, group: HostGroup?) {
        self.model = model; self.group = group
        _name = State(initialValue: group?.title ?? "")
        _appearance = State(initialValue: group.map { model.groupAppearance($0.name) } ?? HostGroupAppearance())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(T(group == nil ? "新建分组" : "编辑分组")).font(.headline)
            GroupAppearanceIcon(appearance: appearance).font(.system(size: 32)).frame(width: 44, height: 44)
                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 4)
            TextField(T("名称"), text: $name).textFieldStyle(.roundedBorder)
                .disabled(group != nil && group?.name == nil)
                .accessibilityIdentifier("Termvia.GroupEditor.Name")
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 36, maximum: 44), spacing: 6)], spacing: 6) {
                    ForEach(choices, id: \.symbol) { choice in
                        Button { appearance.symbol = choice.symbol } label: {
                            Image(systemName: choice.symbol).font(.system(size: 18))
                                .foregroundStyle(Color(nsColor: GroupAppearanceColor.native(appearance.resolvedColorHex)))
                                .frame(maxWidth: .infinity).frame(height: 36)
                                .background(appearance.symbol == choice.symbol ? AppTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(appearance.symbol == choice.symbol ? AppTheme.border : .clear, lineWidth: 1) }
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                            .help(T(choice.title)).accessibilityLabel(T(choice.title))
                            .accessibilityAddTraits(appearance.symbol == choice.symbol ? [.isSelected] : [])
                            .accessibilityIdentifier("Termvia.GroupSymbol." + choice.symbol)
                    }
                }.padding(2)
            }.frame(height: 174)
            HStack(spacing: 4) {
                ForEach(GroupAppearanceColor.presets, id: \.hex) { preset in
                    Toggle(isOn: Binding(get: { appearance.resolvedColorHex == preset.hex }, set: { _ in appearance.colorHex = preset.hex })) {
                        ZStack {
                            Circle().fill(Color(nsColor: GroupAppearanceColor.native(preset.hex))).frame(width: 20, height: 20)
                            Circle().stroke(Color.primary, lineWidth: 1.5).frame(width: 26, height: 26)
                                .opacity(appearance.resolvedColorHex == preset.hex ? 1 : 0)
                        }.frame(width: 32, height: 30).contentShape(Rectangle())
                    }.help(T(preset.name)).accessibilityLabel(T(preset.name))
                        .accessibilityIdentifier("Termvia.GroupColor." + preset.hex)
                }
            }.toggleStyle(.button).buttonStyle(.plain)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(T("恢复默认")) { appearance = HostGroupAppearance() }
                    .accessibilityIdentifier("Termvia.GroupAppearance.Reset")
                Spacer()
                Button(T("取消")) { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("Termvia.GroupAppearance.Cancel")
                Button(T(group == nil ? "创建" : "保存")) {
                    do { try model.saveGroup(name: name, appearance: appearance, editing: group); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("Termvia.GroupAppearance.Save")
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.controlSize(.small).padding(20).frame(width: 400)
    }
    private var choices: [(symbol: String, title: String)] {
        [
            ("folder", "文件夹"), ("folder.fill", "文件夹"), ("server.rack", "服务器"), ("network", "网络"),
            ("desktopcomputer", "台式电脑"), ("laptopcomputer", "笔记本电脑"), ("externaldrive", "磁盘"), ("globe", "全球"),
            ("cloud", "云端"), ("house", "主页"), ("building.2", "建筑"), ("shippingbox", "容器"),
            ("archivebox", "归档"), ("square.stack.3d.up", "集群"), ("star", "星标"), ("heart", "喜爱"),
            ("flag", "旗标"), ("tag", "标签"), ("bolt", "闪电"), ("leaf", "树叶"),
            ("flame", "火焰"), ("shield", "安全"), ("lock", "锁定"), ("key", "密钥"),
            ("gearshape", "设置"), ("terminal", "终端"), ("command", "命令"), ("wifi", "无线网络")
        ]
    }
}
