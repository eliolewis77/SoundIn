// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SoundIn",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Sparkle 2.x：macOS 官方推荐的自动更新框架。
        // 从 2.0 起要求更新包必须用 EdDSA 签名（公钥写入 Info.plist 的 SUPublicEDKey），
        // 且 App 本身需 Developer ID 签名 + 公证，否则 Gatekeeper 会拦下更新后的 App。
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "SoundIn",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources"
        ),
    ]
)
