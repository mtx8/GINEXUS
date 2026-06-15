// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GinexusApp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GinexusApp",
            path: "Sources/GinexusApp"
        )
    ]
)
