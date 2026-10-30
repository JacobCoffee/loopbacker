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
        .target(
            name: "CAirwindows",
            path: "CAirwindows",
            exclude: [
                "README.md",
                "LICENSE.md",
                "awpdoc",
                "Scripts"
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .define("_USE_MATH_DEFINES"),
                // Same suppressions upstream applies to this exact source tree
                // (CMakeLists.txt): these effects were generated decades apart
                // by a Perl script, not hand-tuned for -Wall.
                .unsafeFlags([
                    "-Wno-unused-function",
                    "-Wno-unused-value",
                    "-Wno-unused-but-set-variable",
                    "-Wno-multichar"
                ])
            ]
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
            dependencies: ["CRNNoise", "CYSFX", "CAirwindows", "CWebRTCAEC"],
            path: "Sources",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Accelerate"),
                // Global mute/push-to-talk hotkey (Control slice): RegisterEventHotKey, no
                // Accessibility permission needed.
                .linkedFramework("Carbon")
            ]
        ),
        .testTarget(
            name: "LoopbackerTests",
            dependencies: ["Loopbacker"],
            path: "Tests/LoopbackerTests"
        )
    ],
    cxxLanguageStandard: .cxx17
)
