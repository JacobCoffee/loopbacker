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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
    ],
    targets: [
        .target(
            name: "CRNNoise",
            path: "CRNNoise"
        ),
        .executableTarget(
            name: "Loopbacker",
            dependencies: [
                "CRNNoise",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Accelerate"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "LoopbackerTests",
            dependencies: ["Loopbacker"],
            path: "Tests/LoopbackerTests"
        )
    ]
)
