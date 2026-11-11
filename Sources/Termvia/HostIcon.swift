import AppKit
import SwiftUI

enum HostSystemIcon: String, CaseIterable, Identifiable {
    case server, linux, openwrt, ubuntu, debian, fedora, redhat, arch, alpine, centos, rocky, alma, opensuse, gentoo, nixos, raspbian, kali, mint, manjaro, macos, windows, freebsd
    static let detectionVersion = 2
    static let probeCommand = """
    # termvia-host-system-v2
    uname -s
    if [ -r /etc/os-release ]; then cat /etc/os-release
    elif [ -r /etc/openwrt_release ]; then cat /etc/openwrt_release
    fi
    """
    static let windowsProbeCommand = "cmd /c ver"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .server: return "Server"
        case .linux: return "Linux"
        case .openwrt: return "OpenWrt"
        case .ubuntu: return "Ubuntu"
        case .debian: return "Debian"
        case .fedora: return "Fedora"
        case .redhat: return "Red Hat"
        case .arch: return "Arch Linux"
        case .alpine: return "Alpine Linux"
        case .centos: return "CentOS"
        case .rocky: return "Rocky Linux"
        case .alma: return "AlmaLinux"
        case .opensuse: return "openSUSE"
        case .gentoo: return "Gentoo"
        case .nixos: return "NixOS"
        case .raspbian: return "Raspberry Pi OS"
        case .kali: return "Kali Linux"
        case .mint: return "Linux Mint"
        case .manjaro: return "Manjaro"
        case .macos: return "macOS"
        case .windows: return "Windows"
        case .freebsd: return "FreeBSD"
        }
    }
    static func detect(_ output: String) -> String {
        let lines = output.lowercased().split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains("darwin") { return macos.rawValue }
        if lines.contains("freebsd") { return freebsd.rawValue }
        if lines.contains(where: { $0.contains("mingw") || $0 == "windows_nt" || $0.contains("microsoft windows") }) { return windows.rawValue }
        var release: [String: String] = [:]
        for line in lines {
            let fields = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if fields.count == 2 { release[String(fields[0])] = fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
        }
        func match(_ id: String) -> Self? {
            switch id {
            case "openwrt", "lede", "immortalwrt": return .openwrt
            case "arch", "archlinux": return .arch
            case "alpine", "alpinelinux": return .alpine
            case "rhel", "redhat", "redhatenterpriseserver": return .redhat
            case "rocky", "rockylinux": return .rocky
            case "alma", "almalinux": return .alma
            case "linuxmint", "mint": return .mint
            case "raspbian", "raspberrypi": return .raspbian
            default:
                if id.hasPrefix("opensuse") || id == "suse" || id == "sles" { return .opensuse }
                return Self(rawValue: id)
            }
        }
        if let id = release["id"] ?? release["distrib_id"], let icon = match(id) { return icon.rawValue }
        for id in (release["id_like"] ?? "").split(separator: " ") {
            if let icon = match(String(id)) { return icon.rawValue }
        }
        return lines.contains("linux") ? linux.rawValue : server.rawValue
    }
    var isMulticolor: Bool { self == .linux || self == .openwrt || self == .windows }
    var usesBrandTint: Bool { !isMulticolor && self != .server && self != .macos && self != .alma }
    @MainActor private static var images: [Self: NSImage] = [:]
    @MainActor private static var darkOpenWrt: NSImage?
    @MainActor func image(dark: Bool) -> NSImage? {
        guard self == .openwrt && dark else { return image }
        if let cached = Self.darkOpenWrt { return cached }
        let result = Bundle.module.url(forResource: "openwrt", withExtension: "svg", subdirectory: "HostIcons/Dark").flatMap(NSImage.init(contentsOf:))
        Self.darkOpenWrt = result; return result
    }
    @MainActor var image: NSImage? {
        if let cached = Self.images[self] { return cached }
        let image: NSImage?
        if self == .server { image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil) }
        else {
            let url = Bundle.module.url(forResource: rawValue, withExtension: "svg", subdirectory: "HostIcons/Small")
                ?? Bundle.module.url(forResource: rawValue, withExtension: "svg", subdirectory: "HostIcons")
            image = url.flatMap(NSImage.init(contentsOf:))
        }
        if let image {
            image.isTemplate = !isMulticolor
            Self.images[self] = image
        }
        return image
    }
}

struct HostIcon: View {
    let icon: String
    var selected = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorContrast
    @Environment(\.appearsActive) private var appearsActive
    private var emphasized: Bool { selected && appearsActive }
    private var kind: HostSystemIcon { HostSystemIcon(rawValue: icon) ?? .server }
    var body: some View {
        if let image = kind.image(dark: colorScheme == .dark || emphasized) {
            Group {
                if kind.usesBrandTint && !selected {
                    Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                        .foregroundStyle(Color(nsColor: HostIconPalette.color(kind, dark: colorScheme == .dark, increasedContrast: colorContrast == .increased)))
                } else {
                    Image(nsImage: image).resizable().scaledToFit()
                        .foregroundStyle(selected ? Color.primary : Color(nsColor: .labelColor))
                }
            }.frame(width: 18, height: 18)
                .shadow(color: ((kind == .linux && (colorScheme == .dark || emphasized)) || (kind == .windows && emphasized)) ? .white.opacity(0.8) : .clear, radius: 0.55)
                .accessibilityHidden(true)
        }
    }
}
