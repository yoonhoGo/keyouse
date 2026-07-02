// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "shott",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "shott", path: "Sources/shott")
    ]
)
