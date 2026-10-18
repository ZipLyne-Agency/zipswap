// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZipSwapHandoff",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "ZipSwapBridge", targets: ["ZipSwapBridge"])],
    targets: [
        .target(name: "HandoffCore"),
        .executableTarget(name: "ZipSwapBridge", dependencies: ["HandoffCore"]),
        .testTarget(name: "HandoffCoreTests", dependencies: ["HandoffCore"]),
    ],
    swiftLanguageModes: [.v5]
)
