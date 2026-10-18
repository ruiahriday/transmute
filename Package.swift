// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Transmute",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Transmute", path: "Sources/Transmute")
    ]
)
