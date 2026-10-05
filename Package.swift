// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Switchboard",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Switchboard", path: "Sources/Switchboard")
    ],
    swiftLanguageModes: [.v5]
)
