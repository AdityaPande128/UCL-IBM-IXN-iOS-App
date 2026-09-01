// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JarvisKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "JarvisKit", targets: ["JarvisKit"])],
    targets: [
        .target(name: "JarvisKit", path: "Sources/JarvisKit"),
        .testTarget(name: "JarvisKitTests", dependencies: ["JarvisKit"],
                    path: "Tests/JarvisKitTests"),
    ]
)
