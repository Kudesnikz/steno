// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Steno",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Steno", targets: ["Steno"]),
        .library(name: "StenoCore", targets: ["StenoCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/realm/SwiftLint.git", from: "0.63.2"),
        .package(url: "https://github.com/ggml-org/whisper.spm", revision: "a2085436c2eb796af90956b62bd64731f5e5b823")
    ],
    targets: [
        .target(
            name: "StenoCore",
            dependencies: [
                .product(name: "whisper", package: "whisper.spm")
            ],
            resources: [
                .copy("Resources/Models")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "Steno",
            dependencies: ["StenoCore"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "StenoCoreTests",
            dependencies: ["StenoCore"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
