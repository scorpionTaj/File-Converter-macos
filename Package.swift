// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Kumquat",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Kumquat", targets: ["Kumquat"]),
        .executable(name: "kumquat-cli", targets: ["KumquatCLI"]),
        .library(name: "KumquatCore", targets: ["KumquatCore"]),
    ],
    targets: [
        // Formats, conversion graph, engines. Pure Foundation parts build and test on Linux too.
        .target(name: "KumquatCore"),
        // The menu bar app: drag monitor, radial wheels, HUD, settings.
        .executableTarget(name: "Kumquat", dependencies: ["KumquatCore"]),
        // Scriptable front end to the same engines.
        .executableTarget(name: "KumquatCLI", dependencies: ["KumquatCore"]),
        .testTarget(name: "KumquatCoreTests", dependencies: ["KumquatCore"]),
    ]
)
