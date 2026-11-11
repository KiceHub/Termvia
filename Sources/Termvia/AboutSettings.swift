import AppKit
import SwiftUI
import TermviaCore

/// App identity comes from the signed bundle. Missing development metadata is
/// shown as unavailable rather than inventing a version or a build timestamp.
struct AppInfo {
    let name: String
    let version: String
    let build: String
    let buildDate: Date?
    let author: String
    let copyright: String
    let license: String
    static var current: Self { Self(info: Bundle.main.infoDictionary ?? [:]) }
    init(info: [String: Any]) {
        func string(_ key: String, fallback: String = "—") -> String {
            guard let value = info[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
            return value
        }
        name = string("CFBundleName", fallback: "Termvia")
        version = string("CFBundleShortVersionString")
        build = string("CFBundleVersion")
        buildDate = ISO8601DateFormatter().date(from: string("TermviaBuildDate"))
        author = string("TermviaAuthor")
        copyright = string("NSHumanReadableCopyright")
        license = string("TermviaLicense")
    }
    var versionDescription: String { "\(version) (\(build))" }
    var licenseDescription: String { license == "Apache-2.0" ? "Apache License, Version 2.0" : license }
}

struct AboutSettings: View {
    @Environment(\.locale) private var locale
    private let info = AppInfo.current
    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                        .resizable().frame(width: 72, height: 72).accessibilityHidden(true)
                    Text(info.name).font(.title2.weight(.semibold))
                }.frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            Section {
                LabeledContent(T("版本"), value: info.versionDescription).accessibilityIdentifier("Termvia.About.Version")
                LabeledContent(T("构建时间"), value: info.buildDate.map { $0.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second().locale(locale)) } ?? "—")
                    .accessibilityIdentifier("Termvia.About.BuildDate")
                LabeledContent(T("作者"), value: info.author).accessibilityIdentifier("Termvia.About.Author")
            } footer: {
                VStack(spacing: 6) {
                    Text(info.copyright).accessibilityIdentifier("Termvia.About.Copyright")
                    Link(info.licenseDescription, destination: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!)
                        .accessibilityIdentifier("Termvia.About.License")
                }.frame(maxWidth: .infinity).padding(.vertical, 8)
            }.textSelection(.enabled)
        }.formStyle(.grouped).accessibilityIdentifier("Termvia.About")
    }
}
