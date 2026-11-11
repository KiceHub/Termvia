import AppKit

/// Preserve brand hue while bringing single-color marks above a non-text
/// contrast threshold on the system's light/dark content surfaces.
@MainActor enum HostIconPalette {
    private struct Asset: Decodable { let id: String; let hex: String? }
    private static let brands: [String: NSColor] = {
        guard let url = Bundle.module.url(forResource: "sources", withExtension: "json", subdirectory: "HostIcons"),
              let data = try? Data(contentsOf: url), let assets = try? JSONDecoder().decode([Asset].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: assets.compactMap { asset in
            guard let hex = asset.hex, let value = UInt32(hex, radix: 16) else { return nil }
            return (asset.id, NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1))
        })
    }()
    static func backgrounds(appearance: NSAppearance) -> [NSColor] {
        var colors: [NSColor] = []
        appearance.performAsCurrentDrawingAppearance {
            colors = [NSColor.windowBackgroundColor, .controlBackgroundColor, .textBackgroundColor, .underPageBackgroundColor].compactMap { $0.usingColorSpace(.sRGB) }
        }
        return colors
    }
    static func contrast(_ first: NSColor, _ second: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
            func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    static func color(_ icon: HostSystemIcon, dark: Bool, increasedContrast: Bool = false) -> NSColor {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let surfaces = backgrounds(appearance: appearance)
        let minimum = increasedContrast || [.centos, .kali, .debian, .raspbian].contains(icon) ? 7.0 : 4.5
        let brand = brands[icon.rawValue] ?? (dark ? .white : .black)
        for step in 0...100 {
            let candidate = brand.blended(withFraction: Double(step) / 100, of: dark ? .white : .black) ?? brand
            if surfaces.allSatisfy({ contrast(candidate, $0) >= minimum }) { return candidate }
        }
        return dark ? .white : .black
    }
}
