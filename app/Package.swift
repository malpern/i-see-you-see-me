// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ISeeYou",
    platforms: [
        .macOS("26.0"),
    ],
    targets: [
        .executableTarget(
            name: "ISeeYou",
            path: "Sources/ISeeYou",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // Flip on when building with the Xcode 27 / macOS 27 SDK to compile
                // the multimodal Foundation Models attention estimator.
                // .define("MACOS27_SDK"),
            ])
    ]
)
