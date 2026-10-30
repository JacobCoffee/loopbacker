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
        .target(
            name: "CWebRTCAEC",
            path: "CWebRTCAEC",
            exclude: [
                "LICENSE-webrtc-audio-processing.txt",
                "LICENSE-abseil.txt",
                "README.md",
                "generate.py"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("webrtc"),
                .headerSearchPath("abseil-cpp"),
                .define("WEBRTC_POSIX"),
                .define("WEBRTC_MAC"),
                .define("WEBRTC_ARCH_ARM64"),
                .define("WEBRTC_LIBRARY_IMPL"),
                .define("WEBRTC_APM_DEBUG_DUMP", to: "0"),
                .define("NDEBUG")
            ],
            cxxSettings: [
                .headerSearchPath("webrtc"),
                .headerSearchPath("abseil-cpp"),
                .define("WEBRTC_POSIX"),
                .define("WEBRTC_MAC"),
                .define("WEBRTC_ARCH_ARM64"),
                .define("WEBRTC_LIBRARY_IMPL"),
                .define("WEBRTC_APM_DEBUG_DUMP", to: "0"),
                .define("NDEBUG"),
                .unsafeFlags(["-std=c++17"])
            ]
        ),
        .executableTarget(
            name: "Loopbacker",
            dependencies: ["CRNNoise", "CWebRTCAEC"],
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
