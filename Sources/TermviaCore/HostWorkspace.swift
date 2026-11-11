import Foundation

/// Pane placement is per host. Appearance, language and terminal preferences
/// remain global. The sidebar page belongs to each live tab.
public struct PaneLayout: Codable, Equatable, Sendable {
    public var monitorVisible: Bool
    public var panelVisible: Bool
    public var monitorFraction: Double
    public var terminalFraction: Double
    public var remoteFraction: Double
    public var panel: String
    public init(_ layout: WorkspaceLayout) {
        monitorVisible = layout.monitorVisible; panelVisible = layout.panelVisible
        monitorFraction = layout.monitorFraction; terminalFraction = layout.terminalFraction; remoteFraction = layout.remoteFraction
        panel = layout.panel
    }
    public func applying(to layout: WorkspaceLayout) -> WorkspaceLayout {
        var result = layout
        result.monitorVisible = monitorVisible; result.panelVisible = panelVisible
        result.monitorFraction = monitorFraction; result.terminalFraction = terminalFraction; result.remoteFraction = remoteFraction
        result.panel = panel
        return result.validated()
    }
}
public struct HostWorkspace: Codable, Equatable, Sendable {
    public var layout: PaneLayout
    public var localPath: String
    public var remotePath: String
    public var monitorSelection: MonitorSelection?
    public init(layout: WorkspaceLayout, localPath: String, remotePath: String = "~/") {
        self.layout = PaneLayout(layout); self.localPath = localPath; self.remotePath = remotePath
    }
    public func validated(home: String) -> Self {
        var result = self
        result.layout = PaneLayout(layout.applying(to: WorkspaceLayout()))
        result.monitorSelection = monitorSelection?.validated()
        if !localPath.hasPrefix("/") || localPath.contains("\0") { result.localPath = home }
        if remotePath.isEmpty || remotePath.contains("\0") { result.remotePath = "~/" }
        return result
    }
}

/// A nil device means All. Names are retained even while a device is absent.
public struct MonitorSelection: Codable, Equatable, Sendable {
    public var networkInterface: String?
    public var diskDevice: String?
    public init(networkInterface: String? = nil, diskDevice: String? = nil) {
        self.networkInterface = networkInterface; self.diskDevice = diskDevice
    }
    public func validated() -> Self {
        func device(_ name: String?) -> String? {
            guard let name, !name.isEmpty, name.utf8.count <= 128,
                  name.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            return name
        }
        return Self(networkInterface: device(networkInterface), diskDevice: device(diskDevice))
    }
}
public struct HostWorkspaceStore: Codable, Equatable, Sendable {
    public var version = 1
    public var states: [String: HostWorkspace] = [:]
    public init() {}
    public static func decode(_ data: Data, home: String) throws -> Self {
        var value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1 else { throw SSHError.invalid("不支持的工作区版本") }
        value.states = value.states.mapValues { $0.validated(home: home) }
        return value
    }
}
