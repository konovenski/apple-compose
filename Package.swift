// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "apple-compose",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "apple-compose", targets: ["apple-compose"]),
        .library(name: "AppleComposeCore", targets: ["AppleComposeCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "AppleComposeCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .executableTarget(
            name: "apple-compose",
            dependencies: [
                "AppleComposeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
