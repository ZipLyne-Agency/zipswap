// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZipSwapHandoff",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "ZipSwapBridge", targets: ["ZipSwapBridge"])],
    targets: [
        .target(name: "HandoffCore"),
        .target(name: "ZipSwapCore", dependencies: ["HandoffCore"], path: "Sources/ZipSwap",
                exclude: ["App", "Views", "Model/AppModel.swift", "Model/AppActions.swift", "Model/AppAutoSwitch.swift", "Model/HandoffController.swift", "Services/HandoffIntegration.swift"]),
        .executableTarget(name: "ZipSwapBridge", dependencies: ["HandoffCore"]),
        .testTarget(name: "HandoffCoreTests", dependencies: ["HandoffCore"]),
        .testTarget(name: "ZipSwapCoreTests", dependencies: ["ZipSwapCore", "HandoffCore"]),
    ],
    swiftLanguageModes: [.v5]
)
