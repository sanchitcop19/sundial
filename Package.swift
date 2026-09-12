// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sundial",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Shared by the Mac app and the iOS companion: the model, rules,
        // classifier and storage are pure Foundation and build for both.
        .library(name: "SundialCore", targets: ["SundialCore"]),
    ],
    targets: [
        .target(name: "SundialCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "SundialApp",
            dependencies: ["SundialCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SundialCoreTests",
            dependencies: ["SundialCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
