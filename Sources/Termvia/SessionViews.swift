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
                    }.padding(20).glassEffect(.regular, in: .rect(cornerRadius: 20))
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
    @ObservedObject private var state: Session
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    var reconnect: (() -> Void)? = nil
    var rename: (() -> Void)? = nil
    let findAction: NativeSessionTab.Action?
    var splitActions: [NativeSessionTab.Action] = []
    var hostIcon: String? = nil
    var doubleClickCloses = true
    init(session: Session, selected: Bool, select: @escaping () -> Void, close: @escaping () -> Void, reconnect: (() -> Void)? = nil, rename: (() -> Void)? = nil, findAction: NativeSessionTab.Action? = nil, splitActions: [NativeSessionTab.Action] = [], hostIcon: String? = nil, doubleClickCloses: Bool = true, statusSession: Session? = nil) {
        self.session = session; self.state = statusSession ?? session; self.selected = selected; self.select = select; self.close = close
        self.reconnect = reconnect; self.rename = rename; self.splitActions = splitActions; self.hostIcon = hostIcon; self.doubleClickCloses = doubleClickCloses
        self.findAction = findAction
    }
    @State private var hovered = false
    var displayTitle: String { session.customTabTitle ?? state.tabTitle }
    var body: some View {
        NativeSessionTab(content: AnyView(content.environment(\.locale, uiLocale).environment(\.colorScheme, colorScheme).environment(\.appearsActive, appearsActive)), actions: menuActions, onDoubleClick: doubleClickCloses ? close : nil, identifier: "Termvia.TabContainer.\(session.id)")
            .frame(height: 30).onHover { hovered = $0 }
    }
    private var content: some View {
        CompactTabContent(title: displayTitle, selected: selected, hovered: hovered, select: select, close: close,
                          closeLabel: T("关闭 %@", session.tabTitle), identifier: "Termvia.Tab.\(session.id)", closeIdentifier: "Termvia.Tab.Close.\(session.id)",
                          status: state.status, help: "\(session.tabTitle) · \(state.status) · \(state.dimensions)") {
            if state.phase == .connecting { ProgressView().progressViewStyle(.circular).controlSize(.mini).accessibilityLabel(T("正在连接")) }
            else if session.isStartPage { Image(systemName: "house") }
            else if state.host != nil && state.isDisconnected {
                BrokenLinkSymbol().foregroundStyle(.secondary)
                    .accessibilityIdentifier("Termvia.Tab.Disconnected.\(session.id)").accessibilityLabel(T("已断开"))
            }
            else if state.connected, state.host != nil {
                HostIcon(icon: hostIcon ?? state.host?.customIcon ?? state.host?.detectedSystem ?? "server")
                    .scaleEffect(0.8).frame(width: 14, height: 14)

#if TERMVIA_DIAGNOSTICS
                    .background(GeometryCheckProbe(role: "tab-host-icon-\(session.id)"))
#endif

            }
            else { Image(systemName: "terminal") }
        }
    }
    var menuActions: [NativeSessionTab.Action] {
        var actions: [NativeSessionTab.Action] = []
        if let rename {
            actions.append(.init(T("重命名"), action: rename))
            if session.customTabTitle != nil { actions.append(.init(T("恢复默认名称")) { session.renameTab("") }) }
            actions.append(.separator)
        }
        if !session.isStartPage {
            if let findAction { actions.append(findAction) }
            actions.append(.init(T("停止"), enabled: state.phase.isActive || state.reconnectPending) { state.stop() })
            if let reconnect { actions.append(.init(T("重新连接"), enabled: !state.restarting, action: reconnect)) }
        }
        actions += splitActions
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
