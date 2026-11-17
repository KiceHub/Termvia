import AppKit
import SwiftUI

/// The close control replaces the tab's normal icon, without changing its width.
struct CompactTabContent<Icon: View>: View {
    let title: String
    let selected: Bool
    let hovered: Bool
    let select: () -> Void
    let close: () -> Void
    let closeLabel: String
    let identifier: String
    let closeIdentifier: String
    var status = ""
    var help = ""
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        Button(action: select) {
            HStack(spacing: 4) {
                icon().frame(width: 14, height: 14).opacity(hovered ? 0 : 1).accessibilityHidden(hovered)
                Text(title).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160)
            }.frame(minWidth: 20, maxHeight: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier(identifier).accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityValue(status).accessibilityAction(named: Text(closeLabel), close)
            .font(.system(size: 12, weight: selected ? .medium : .regular))
            .padding(.leading, 8).padding(.trailing, 15).frame(height: 30)
            .modifier(SessionCapsule(selected: selected, hovered: hovered))
            .overlay(alignment: .leading) {
                if hovered {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                            .frame(width: 18, height: 20).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.leading, 6)
                        .help(closeLabel).accessibilityLabel(closeLabel).accessibilityIdentifier(closeIdentifier)
                }
            }.help(help)
    }
}

@MainActor enum WorkspaceChrome {
    static func apply(to window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = AppTheme.nativeSurface
    }
}
