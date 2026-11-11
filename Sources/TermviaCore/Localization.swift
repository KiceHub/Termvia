import Foundation

/// Persist BCP 47 identifiers, keeping existing saved language choices valid.
public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system, chinese = "zh-Hans", traditionalChinese = "zh-Hant"
    case japanese = "ja", korean = "ko", russian = "ru", english = "en", french = "fr", german = "de"
    public static var supported: [Self] { allCases.filter { $0 != .system } }
    public var title: String {
        switch self {
        case .system: return T("跟随系统")
        case .chinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .russian: return "Русский"
        case .english: return "English"
        case .french: return "Français"
        case .german: return "Deutsch"
        }
    }
}

/// Native, bundle-backed i18n shared by SwiftUI, AppKit and command errors.
/// Resource bundles and locales are resolved once, rather than reopening paths
/// for every monitor refresh or menu item. Foundation caches tables on demand.
public enum Localization {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var selected = AppLanguage.system
    public static var preference: AppLanguage {
        get { lock.lock(); defer { lock.unlock() }; return selected }
        set { lock.lock(); selected = newValue; lock.unlock() }
    }
    private static let supportedIdentifiers = ["en"] + AppLanguage.supported.map(\.rawValue).filter { $0 != "en" }
    private static let systemIdentifier = identifier(for: .system)
    public static func identifier(for preference: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard preference == .system else { return preference.rawValue }
        // Foundation handles regional and script variants, including zh-TW,
        // zh-HK, zh-Hant and zh-Hans, in the user's preference order.
        return Bundle.preferredLocalizations(from: supportedIdentifiers, forPreferences: preferredLanguages).first ?? "en"
    }
    public static var locale: Locale { locale(for: preference) }
    public static func locale(for language: AppLanguage) -> Locale { locales[effectiveIdentifier(language)] ?? locales["en"]! }
    private static func effectiveIdentifier(_ language: AppLanguage) -> String { language == .system ? systemIdentifier : language.rawValue }
    private static let locales = Dictionary(uniqueKeysWithValues: supportedIdentifiers.map { ($0, Locale(identifier: $0)) })
    public static let resourceBundle: Bundle = {
        // Prefer resources shipped in the app over SwiftPM's development path.
        if let resources = Bundle.main.resourceURL {
            for name in ["Termvia_TermviaCore", "termvia_TermviaCore"] {
                if let bundle = Bundle(url: resources.appendingPathComponent(name + ".bundle")) { return bundle }
            }
        }
        return .module
    }()
    private static let bundles: [String: Bundle] = Dictionary(uniqueKeysWithValues: supportedIdentifiers.compactMap { identifier in
        resourceBundle.path(forResource: identifier, ofType: "lproj").flatMap(Bundle.init(path:)).map { (identifier, $0) }
    })
    /// Explicitly invariant UI labels. Monitor abbreviations, protocol names,
    /// POSIX rate units, paths, host names and terminal output bypass T entirely.
    public static let verbatimKeys: Set<String> = ["Local", "语言 / Language"]
    private static let missing = "\u{1f}Termvia.MissingLocalization"
    public static func text(_ key: String, arguments: [CVarArg] = [], language: AppLanguage? = nil) -> String {
        let identifier = verbatimKeys.contains(key) ? "en" : effectiveIdentifier(language ?? preference)
        let localized = bundles[identifier]?.localizedString(forKey: key, value: missing, table: "Localizable") ?? missing
        let format = localized == missing
            ? bundles["en"]?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
            : localized
        return arguments.isEmpty ? format : String(format: format, locale: locales[identifier] ?? locales["en"]!, arguments: arguments)
    }
}

public func T(_ key: String, _ arguments: CVarArg...) -> String { Localization.text(key, arguments: arguments) }
