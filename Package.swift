// swift-tools-version:5.9
import PackageDescription

// This package is for editor/IDE support and `swift build`. The shippable
// .app bundle (with Info.plist and LSUIElement) is produced by ./build.sh.
let package = Package(
    name: "PositionLauncher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PositionLauncher",
            path: "Sources/PositionLauncher"
        )
    ],
    swiftLanguageVersions: [.v5]
)
