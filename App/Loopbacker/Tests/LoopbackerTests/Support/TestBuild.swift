/// Whether the code under test was compiled with optimization. SwiftPM defines `DEBUG` only
/// for debug builds.
enum TestBuild {
    #if DEBUG
    static let isOptimized = false
    #else
    static let isOptimized = true
    #endif
}
