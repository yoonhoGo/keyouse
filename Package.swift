// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "keyouse",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "keyouse", path: "Sources/keyouse")
    ]
)
