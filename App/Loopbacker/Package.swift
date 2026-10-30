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
        .executableTarget(
            name: "Loopbacker",
            dependencies: ["CRNNoise", "CAirwindows"],
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
    ],
    cxxLanguageStandard: .cxx17
)
