import AppKit
import SwiftUI

@MainActor enum AppAppearance {
    static func override(for preference: String) -> NSAppearance? {
        switch preference {
        case "深色": NSAppearance(named: .darkAqua)
        case "浅色": NSAppearance(named: .aqua)
        default: nil
        }
    }
    static func scheme(for appearance: NSAppearance) -> ColorScheme {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
    static func resolve(_ preference: String, inherited: NSAppearance) -> ColorScheme {
        scheme(for: override(for: preference) ?? inherited)
    }
}
