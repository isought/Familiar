// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Familiar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Familiar",
            path: "Sources/Familiar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
