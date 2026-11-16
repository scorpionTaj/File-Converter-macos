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
        // Formats, conversion graph, engines.
        .target(name: "KumquatCore"),
        // The menu bar app: drag monitor, radial wheels, HUD, settings.
        .executableTarget(name: "Kumquat", dependencies: ["KumquatCore"]),
        // Scriptable front end to the same engines.
        .executableTarget(name: "KumquatCLI", dependencies: ["KumquatCore"]),
        // Finder Quick Action and Share extension: hand files to the app. Packaged into two .appex bundles by
        // scripts/build-app.sh; an app extension starts in NSExtensionMain instead of main.
        .executableTarget(name: "KumquatExtension",
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]),
        .testTarget(name: "KumquatCoreTests", dependencies: ["KumquatCore"]),
    ]
)
