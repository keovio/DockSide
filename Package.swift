// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DockSide",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "DockSide", path: "Sources/DockSide")
    ]
)
