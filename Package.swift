// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "iPodConverter",
    platforms: [.macOS(.v14)],
    targets: [
        // GTK4 + libadwaita — только для Linux-версии (на Mac не собирается и не нужен).
        .systemLibrary(name: "CGtk", path: "Sources/CGtk", pkgConfig: "libadwaita-1",
                       providers: [.apt(["libadwaita-1-dev", "libgtk-4-dev"])]),
        .executableTarget(
            name: "iPodConverter",
            dependencies: [.target(name: "CGtk", condition: .when(platforms: [.linux]))],
            path: "Sources/iPodConverter"
        )
    ]
)
