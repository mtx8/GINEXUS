// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GinexusApp",
    platforms: [.macOS(.v14)],
    products: [
        // Exposed so the Xcode app project (GINEXUS.xcodeproj) can depend on it.
        .library(name: "GinexusCore", targets: ["GinexusCore"]),
    ],
    targets: [
        // Shared, independently-testable core (UDS HTTP client, sidecar control).
        .target(name: "GinexusCore"),
        // The SwiftUI app.
        .executableTarget(name: "GinexusApp", dependencies: ["GinexusCore"], path: "Sources/GinexusApp"),
        // A tiny CLI to verify the UDS client against the live sidecar from the shell.
        .executableTarget(name: "udsprobe", dependencies: ["GinexusCore"], path: "Sources/udsprobe"),
        .testTarget(name: "GinexusCoreTests", dependencies: ["GinexusCore"]),
    ]
)
