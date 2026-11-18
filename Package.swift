// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Windowsill",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Windowsill", path: "Sources/Windowsill")
    ]
)
