import Foundation

public struct HostGroupAppearance: Codable, Equatable, Sendable {
    public static let defaultColorHex = "4D86D4"
    public var symbol: String
    public var colorHex: String?
    public var resolvedColorHex: String { colorHex ?? Self.defaultColorHex }
    public init(symbol: String = "folder", colorHex: String? = nil) { self.symbol = symbol; self.colorHex = colorHex }
    public func validated() -> Self {
        var value = self
        value.symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.symbol.isEmpty { value.symbol = "folder" }
        if let colorHex {
            let hex = colorHex.hasPrefix("#") ? String(colorHex.dropFirst()) : colorHex
            value.colorHex = hex.count == 6 && hex.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) ? hex.uppercased() : nil
        }
        return value
    }
    public static func key(for group: String?) -> String { group.map { "group:" + $0 } ?? "ungrouped" }
}
