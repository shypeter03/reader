// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SherpaKokoroKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "SherpaKokoroKit", targets: ["SherpaKokoroKit"]),
        .executable(name: "kokoro-selftest", targets: ["KokoroSelfTest"]),
    ],
    dependencies: [
        // k2-fsa 官方 SwiftPM 入口：仓库根的 Package.swift 已经带好
        // 预编译 iOS/macOS xcframework（静态）+ onnxruntime 二进制，
        // 不需要自己编译 sherpa-onnx。版本锁死：xcframework URL 里写死了版本号。
        .package(url: "https://github.com/k2-fsa/sherpa-onnx", exact: "1.13.8"),
    ],
    targets: [
        .target(
            name: "SherpaKokoroKit",
            dependencies: [
                .product(name: "sherpa-onnx", package: "sherpa-onnx")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "KokoroSelfTest",
            dependencies: ["SherpaKokoroKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
