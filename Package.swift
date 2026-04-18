// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Reader",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
    ],
    targets: [
        .executableTarget(
            name: "Reader",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
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
