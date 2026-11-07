// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacOSLens",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacOSLens", targets: ["MacOSLens"])],
    targets: [
        .target(name: "LensCore"),
        .executableTarget(name: "MacOSLens", dependencies: ["LensCore"]),
        .executableTarget(name: "LensCoreTests", dependencies: ["LensCore"], path: "Tests/LensCoreTests")
    ]
)
