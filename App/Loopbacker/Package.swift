// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Loopbacker",
    platforms: [
        .macOS(.v14)
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
                .linkedFramework("AVFoundation")
            ]
        )
    ]
)
