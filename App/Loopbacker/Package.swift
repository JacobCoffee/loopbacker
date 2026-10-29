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
        .executableTarget(
            name: "Loopbacker",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreML"),
                .linkedFramework("Accelerate")
            ]
        )
    ]
)
