import SwiftUI
import TermviaCore

/// Observe the session here: AppModel does not republish child object changes.
struct SessionTerminalPane: View {
    @ObservedObject var session: Session
    let focusRevision: Int
    let canFocus: Bool
    var terminalInsets = TerminalInsets()
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                TerminalSurface(session: session, focusRevision: focusRevision, canFocus: canFocus && session.phase != .connecting, insets: terminalInsets)
                if session.phase == .connecting {
                    VStack(spacing: 10) {
                        ProgressView().progressViewStyle(.circular).controlSize(.regular)
                        Text(T("正在连接")).font(.callout)
                    }.padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityElement(children: .combine).accessibilityLabel(T("正在连接"))

#if TERMVIA_DIAGNOSTICS
                        .background(AppearanceCheckProbe(role: "session-connecting"))
#endif

                }
            }
        }
    }
}

struct SessionTab: View {
    @Environment(\.locale) private var uiLocale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appearsActive) private var appearsActive
    @ObservedObject var session: Session
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    var reconnect: (() -> Void)? = nil
    var rename: (() -> Void)? = nil
    var hostIcon: String? = nil
    var doubleClickCloses = true
    @State private var hovered = false
    var body: some View {
        NativeSessionTab(content: AnyView(content.environment(\.locale, uiLocale).environment(\.colorScheme, colorScheme).environment(\.appearsActive, appearsActive)), actions: menuActions, onDoubleClick: doubleClickCloses ? close : nil, identifier: "Termvia.TabContainer.\(session.id)")
            .frame(height: 30).onHover { hovered = $0 }
    }
    private var content: some View {
        HStack(spacing: 8) {
            Button(action: select) {
                HStack(spacing: 6) {
                    if session.phase == .connecting { ProgressView().progressViewStyle(.circular).controlSize(.mini).accessibilityLabel(T("正在连接")) }
                    else if session.isStartPage { Image(systemName: "house") }
                    else if session.host != nil && session.isDisconnected {
                        BrokenLinkSymbol().foregroundStyle(.secondary)
                            .accessibilityIdentifier("Termvia.Tab.Disconnected.\(session.id)").accessibilityLabel(T("已断开"))
                    }
                    else if session.connected, session.host != nil {
                        HostIcon(icon: hostIcon ?? session.host?.customIcon ?? session.host?.detectedSystem ?? "server")
                            .scaleEffect(0.8).frame(width: 14, height: 14)

#if TERMVIA_DIAGNOSTICS
                            .background(GeometryCheckProbe(role: "tab-host-icon-\(session.id)"))
#endif

                    }
                    Text(session.tabTitle).lineLimit(1)
                }.frame(minWidth: 20, maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).help("\(session.tabTitle) · \(session.status) · \(session.dimensions)")
                .accessibilityIdentifier("Termvia.Tab.\(session.id)")
                .accessibilityAddTraits(selected ? [.isSelected] : []).accessibilityValue(session.status)
            Button(action: close) { Image(systemName: "xmark").font(.caption2).frame(width: 20, height: 20).contentShape(Rectangle()) }
                .buttonStyle(.plain).help(T("关闭 %@", session.tabTitle)).accessibilityLabel(T("关闭 %@", session.tabTitle))
        }.font(.system(size: 12, weight: selected ? .medium : .regular)).padding(.horizontal, 10).frame(height: 30)
            .modifier(SessionCapsule(selected: selected, hovered: hovered))
    }
    private var menuActions: [NativeSessionTab.Action] {
        var actions: [NativeSessionTab.Action] = []
        if let rename {
            actions.append(.init(T("重命名"), action: rename))
            if session.customTabTitle != nil { actions.append(.init(T("恢复默认名称")) { session.renameTab("") }) }
            actions.append(.separator)
        }
        if !session.isStartPage {
            actions.append(.init(T("停止"), enabled: session.phase.isActive || session.reconnectPending) { session.stop() })
            if let reconnect { actions.append(.init(T("重新连接"), enabled: !session.restarting, action: reconnect)) }
        }
        actions.append(.init(T("关闭标签页"), action: close))
        return actions
    }
}

/// Clear glass adds a bright specular rim in dark titlebars. Use the system's
/// low-emphasis fill for hover there, keeping selection and light glass intact.
struct SessionCapsule: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    var selected = false
    let hovered: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        if selected {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else if scheme == .dark {
            content.background {
                if hovered { Capsule().fill(contrast == .increased ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary)) }
            }
        } else {
            content.glassEffect(hovered ? .clear.interactive() : .identity, in: .capsule)
        }
    }
}
