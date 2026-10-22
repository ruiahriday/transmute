// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Transmute",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Transmute", path: "Sources/Transmute",
            // Linked explicitly: the video editor's player view failed to load without it.
            linkerSettings: [.linkedFramework("AVKit"), .linkedFramework("Quartz"), .linkedFramework("Vision"),
                             .linkedFramework("ScreenCaptureKit"), .linkedFramework("Carbon")]
        )
    ]
)
