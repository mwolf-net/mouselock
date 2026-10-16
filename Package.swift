// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MouseLock",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "MouseLock", path: "Sources/MouseLock"),
    ]
)
