// swift-tools-version: 6.2
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent(path).path) }

// Private acceptance tools and test targets are optional in source releases.
let diagnostics = ProcessInfo.processInfo.environment["TERMVIA_DIAGNOSTICS"] == "1"
    && exists("Sources/Termvia/Diagnostics")
let hasProbe = exists("Sources/TermviaProbe")
var products: [Product] = [.executable(name: "Termvia", targets: ["Termvia"]),
                           .executable(name: "termvia-askpass", targets: ["TermviaAskpass"])]
var targets: [Target] = [
    .target(name: "TermviaCore", resources: [.process("Resources")]),
    .executableTarget(name: "Termvia", dependencies: ["TermviaCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
                      exclude: diagnostics ? [] : ["Diagnostics"].filter { exists("Sources/Termvia/" + $0) },
                      resources: [.copy("Resources/HostIcons")],
                      swiftSettings: diagnostics ? [.define("TERMVIA_DIAGNOSTICS")] : []),
    .executableTarget(name: "TermviaAskpass", dependencies: ["TermviaCore"])
]
if hasProbe {
    products.append(.executable(name: "termvia-probe", targets: ["TermviaProbe"]))
    targets.append(.executableTarget(name: "TermviaProbe", dependencies: ["TermviaCore"]))
}
if exists("Tests/TermviaCoreTests") {
    targets.append(.testTarget(name: "TermviaCoreTests", dependencies: ["TermviaCore"]))
}
if diagnostics && exists("Tests/TermviaAppTests") {
    targets.append(.testTarget(name: "TermviaAppTests", dependencies: ["Termvia", "TermviaCore"]))
}

let package = Package(
    name: "Termvia",
    defaultLocalization: "en",
    platforms: [.macOS("27.0")],
    products: products,
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.2")],
    targets: targets,
    swiftLanguageModes: [.v5]
)
