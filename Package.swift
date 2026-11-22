// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "iPodConverter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "iPodConverter", path: "Sources/iPodConverter")
    ]
)
