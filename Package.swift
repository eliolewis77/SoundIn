// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SoundIn",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "SoundIn",
            path: "Sources"
        ),
    ]
)
