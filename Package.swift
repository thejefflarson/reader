// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Reader",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Pinned to an exact version to prevent a future compromised Sparkle
        // release from being silently consumed on the next `swift package update`.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.6.4"),
        // swift-markdown likewise pinned; the parser sits on the trust path
        // for every keystroke and we don't want silent upgrades.
        .package(url: "https://github.com/apple/swift-markdown", exact: "0.8.0"),
    ],
    targets: [
        .executableTarget(
            name: "Reader",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/Reader"
        ),
        .testTarget(
            name: "ReaderTests",
            dependencies: ["Reader"],
            path: "Tests/ReaderTests"
        ),
    ]
)
