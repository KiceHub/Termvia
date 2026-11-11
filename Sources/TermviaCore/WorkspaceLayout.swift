import Foundation

public struct WorkspaceLayout: Codable, Equatable, Sendable {
    public var monitorVisible = true
    public var panelVisible = true
    public var monitorFraction = 0.17
    public var terminalFraction = 0.62
    public var remoteFraction = 0.52
    public var panel = "文件"
    public var appearance = "系统"
    public var fontSize = 13.0
    public var language = AppLanguage.system
    public var sidebarPage = "hosts"
    public var collapsedHostGroups: [String] = []
    public var showHiddenFiles = false
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case monitorVisible, panelVisible, monitorFraction, terminalFraction, remoteFraction, panel, appearance, fontSize, language, sidebarPage, collapsedHostGroups, showHiddenFiles
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        monitorVisible = try values.decodeIfPresent(Bool.self, forKey: .monitorVisible) ?? true
        panelVisible = try values.decodeIfPresent(Bool.self, forKey: .panelVisible) ?? true
        monitorFraction = try values.decodeIfPresent(Double.self, forKey: .monitorFraction) ?? 0.17
        terminalFraction = try values.decodeIfPresent(Double.self, forKey: .terminalFraction) ?? 0.62
        remoteFraction = try values.decodeIfPresent(Double.self, forKey: .remoteFraction) ?? 0.52
        panel = try values.decodeIfPresent(String.self, forKey: .panel) ?? "文件"
        appearance = try values.decodeIfPresent(String.self, forKey: .appearance) ?? "系统"
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
        language = (try values.decodeIfPresent(String.self, forKey: .language)).flatMap(AppLanguage.init(rawValue:)) ?? .system
        sidebarPage = try values.decodeIfPresent(String.self, forKey: .sidebarPage) ?? "hosts"
        collapsedHostGroups = try values.decodeIfPresent([String].self, forKey: .collapsedHostGroups) ?? []
        showHiddenFiles = try values.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) ?? false
    }
    public func validated() -> Self {
        var value = self
        value.monitorFraction = monitorFraction.isFinite ? min(0.95, max(0.05, monitorFraction)) : 0.17
        value.terminalFraction = terminalFraction.isFinite ? min(0.95, max(0.05, terminalFraction)) : 0.62
        value.remoteFraction = remoteFraction.isFinite ? min(0.95, max(0.05, remoteFraction)) : 0.52
        value.fontSize = fontSize.isFinite ? min(28, max(10, fontSize)) : 13
        if !["文件", "传输", "日志"].contains(panel) { value.panel = "文件" }
        if !["系统", "浅色", "深色"].contains(appearance) { value.appearance = "系统" }
        if !["hosts", "monitor"].contains(sidebarPage) { value.sidebarPage = "hosts" }
        value.collapsedHostGroups = Array(Set(collapsedHostGroups)).sorted()
        return value
    }
}
