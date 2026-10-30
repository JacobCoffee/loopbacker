import Foundation

/// Where Loopbacker keeps its own files (routing config, scenes, effects presets, soundboard,
/// automation rules, plugin crash sentinels).
///
/// Only the real app bundle gets `~/Library/Application Support/Loopbacker`. Any other process
/// that links this code -- the unit tests above all, or an unbundled `swift run` -- gets a
/// private temporary folder instead, so it can never overwrite the installed app's config.
/// A test that constructed a `RoutingState` without a directory and called `save()` once wiped
/// the maintainer's sources and routes this way.
enum AppDataDirectory {
    static let appBundleIdentifier = "com.jacobcoffee.loopbacker"

    static let url: URL = {
        if Bundle.main.bundleIdentifier == appBundleIdentifier {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return appSupport.appendingPathComponent("Loopbacker", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("Loopbacker-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }()
}
