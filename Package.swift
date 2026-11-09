// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacOSLens",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacOSLens", targets: ["MacOSLens"])],
    targets: [
        .target(name: "LensCore"),
        // Translation arrived in macOS 15; weak linking keeps the app launching on macOS 14.
        .executableTarget(name: "MacOSLens", dependencies: ["LensCore"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "Translation",
                                                         "-Xlinker", "-weak_framework", "-Xlinker", "_Translation_SwiftUI"])]),
        .executableTarget(name: "LensCoreTests", dependencies: ["LensCore"], path: "Tests/LensCoreTests")
    ]
)
