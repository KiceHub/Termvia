import TermviaCore
import AppKit
import SwiftUI

enum AppTheme {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let elevated = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let accent = Color.accentColor
    static let terminal = Color(nsColor: .textBackgroundColor)
    static let terminalText = Color(nsColor: .textColor)
}

struct BrandMark: View {
    private static let appIcon = Bundle.main.url(forResource: "Termvia", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
    @Environment(\.locale) private var uiLocale
    var size: CGFloat = 32
    var body: some View {
        let _ = uiLocale.identifier
        Group {
            if let image = Self.appIcon {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.055)], startPoint: .top, endPoint: .bottom))
                    Path { path in
                        path.move(to: CGPoint(x: size * 0.27, y: size * 0.32))
                        path.addLine(to: CGPoint(x: size * 0.45, y: size * 0.50))
                        path.addLine(to: CGPoint(x: size * 0.27, y: size * 0.68))
                    }.stroke(.white, style: StrokeStyle(lineWidth: size * 0.065, lineCap: .round, lineJoin: .round))
                    Path { path in
                        path.move(to: CGPoint(x: size * 0.57, y: size * 0.68))
                        path.addLine(to: CGPoint(x: size * 0.77, y: size * 0.68))
                    }.stroke(Color(white: 0.886), style: StrokeStyle(lineWidth: size * 0.065, lineCap: .round))
                }
            }
        }.frame(width: size, height: size).accessibilityLabel("Termvia")
    }
}

struct StatusPill: View {
    @Environment(\.locale) private var uiLocale
    let title: String
    var color: Color = AppTheme.accent
    var body: some View {
        let _ = uiLocale.identifier
        HStack(spacing: 5) { Circle().fill(color).frame(width: 5, height: 5); Text(T(title)).font(.system(size: 10, weight: .medium)) }
            .foregroundStyle(color)
    }
}

struct PaneHeading: View {
    @Environment(\.locale) private var uiLocale
    let title: String
    let symbol: String
    var detail: String = ""
    var body: some View {
        let _ = uiLocale.identifier
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(T(title)).font(.callout.weight(.semibold))
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            Spacer(minLength: 0)
        }.frame(height: 24)
    }
}

struct EmptyPane: View {
    @Environment(\.locale) private var uiLocale
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        let _ = uiLocale.identifier
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 20)).frame(width: 24, height: 24).foregroundStyle(.tertiary)
            Text(T(title)).font(.callout).foregroundStyle(.secondary)
            if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TerminalWelcome: View {
    @Environment(\.locale) private var uiLocale
    let hosts: () -> Void
    let local: () -> Void
    var staticPreview = false
    var body: some View {
        let _ = uiLocale.identifier
        VStack(spacing: 16) {
            BrandMark(size: 36)
            if staticPreview { previewButtons }
            else { HStack(spacing: 8) {
                Button("SSH", systemImage: "plus", action: hosts).help(T("连接主机 · ⌘N"))
                Button(T("Local"), systemImage: "terminal", action: local).help(T("本地终端 · ⌘T"))
            }.controlSize(.regular) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.terminal)
    }
    private var previewButtons: some View {
#if TERMVIA_DIAGNOSTICS
        Image(nsImage: NativeControlPreview.welcomeButtons())
#else
        EmptyView()
#endif
    }
}
