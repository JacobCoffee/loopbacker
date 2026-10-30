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
            name: "CYSFX",
            path: "CYSFX",
            exclude: [
                "README.md",
                "ysfx-sources/eel2-gas/LICENSE.txt",
                "stb/LICENSE",
                "WDL/eel2/asm-nseel-aarch64-gcc.c",
                "WDL/eel2/y.tab.c"
            ],
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("include"),
                .headerSearchPath("ysfx-sources"),
                .headerSearchPath("stb"),
                .define("WDL_FFT_REALSIZE", to: "8"),
                .unsafeFlags(["-fsigned-char", "-fno-objc-arc"])
            ],
            cxxSettings: [
                .headerSearchPath("."),
                .headerSearchPath("include"),
                .headerSearchPath("ysfx-sources"),
                .headerSearchPath("stb"),
                .define("WDL_FFT_REALSIZE", to: "8"),
                .unsafeFlags(["-fsigned-char", "-fno-objc-arc", "-std=c++17"])
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Carbon"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("OpenGL")
            ]
        ),
        .executableTarget(
            name: "Loopbacker",
            dependencies: ["CRNNoise", "CYSFX"],
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
