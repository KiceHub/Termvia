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
                           .executable(name: "termvia-askpass", targets: ["TermviaAskpass"]), .executable(name: "termvia-proxy", targets: ["TermviaProxy"])]
var targets: [Target] = [
    .target(name: "TermviaCore", resources: [.process("Resources")]),
    .executableTarget(name: "Termvia", dependencies: ["TermviaCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
                      exclude: diagnostics ? [] : ["Diagnostics"].filter { exists("Sources/Termvia/" + $0) },
                      resources: [.copy("Resources/HostIcons")],
                      swiftSettings: diagnostics ? [.define("TERMVIA_DIAGNOSTICS")] : []),
    .executableTarget(name: "TermviaAskpass", dependencies: ["TermviaCore"]),
    .executableTarget(name: "TermviaProxy", dependencies: ["TermviaCore"])
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
    // This revision exposes coordinate selection on macOS for terminal search.
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", revision: "e1ff7f7b763dc194365f91dfd69cbbfc3810e13f")],
    targets: targets,
    swiftLanguageModes: [.v5]
)
