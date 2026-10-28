// swift-tools-version: 6.0
// LoreGraphKit: everything the iOS app does that is not drawing. It builds and tests on Linux
// as well as on Apple platforms (scripts/test.sh), so the logic is covered without a simulator.
import PackageDescription

let package = Package(
    name: "LoreGraphKit",
    defaultLocalization: "en",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [
        .library(name: "LoreGraphKit", targets: ["LoreGraphKit"]),
    ],
    targets: [
        .target(name: "LoreGraphKit", path: "Sources/LoreGraphKit"),
        .testTarget(
            name: "LoreGraphKitTests",
            dependencies: ["LoreGraphKit"],
            path: "Tests/LoreGraphKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
