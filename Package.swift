// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Windowsill",
    platforms: [.macOS("26.0")],   // tested on macOS 26 and 27 only
    targets: [
        .executableTarget(name: "Windowsill", path: "Sources/Windowsill")
    ]
)
