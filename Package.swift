// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Posture",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Posture",
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PostureTests",
            dependencies: ["Posture"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
