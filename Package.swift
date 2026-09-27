// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Familiar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "FamiliarContracts",
            path: "Sources/FamiliarContracts"
        ),
        .target(
            name: "FamiliarRuntime",
            dependencies: ["FamiliarContracts"],
            path: "Sources/FamiliarRuntime"
        ),
        .executableTarget(
            name: "Familiar",
            dependencies: ["FamiliarContracts", "FamiliarRuntime"],
            path: "Sources/Familiar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "FamiliarTests",
            dependencies: ["Familiar", "FamiliarContracts", "FamiliarRuntime"],
            path: "Tests/FamiliarTests"
        ),
        .testTarget(
            name: "FamiliarRuntimeTests",
            dependencies: ["FamiliarContracts", "FamiliarRuntime"],
            path: "Tests/FamiliarRuntimeTests"
        )
    ]
)
