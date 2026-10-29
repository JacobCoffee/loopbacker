// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Loopbacker",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Loopbacker", targets: ["Loopbacker"])
    ],
    targets: [
        .target(
            name: "CRNNoise",
            path: "CRNNoise"
        ),
        .executableTarget(
            name: "Loopbacker",
            dependencies: ["CRNNoise"],
            path: "Sources",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Accelerate")
            ]
        ),
        .testTarget(
            name: "LoopbackerTests",
            dependencies: ["Loopbacker"],
            path: "Tests/LoopbackerTests"
        )
    ]
)
