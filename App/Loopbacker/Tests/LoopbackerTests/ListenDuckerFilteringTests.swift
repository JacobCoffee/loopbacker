import Foundation
import Testing
@testable import Loopbacker

/// `ListenDucker.sanitizedBundleIDs` is the pure filter applied to the user's "duck what I
/// hear" app set before a tap is ever built -- excludes Loopbacker's own process (never a
/// sensible duck target) and anything currently counted as a call app (ducking a call app on
/// the user's own output would duck the call itself). `@MainActor` since `ListenDucker` is.
@MainActor
@Suite("ListenDucker.sanitizedBundleIDs (app-set filtering)")
struct ListenDuckerFilteringTests {
    @Test("Passes through apps that aren't call apps or Loopbacker itself")
    func passesThroughOrdinaryApps() {
        let result = ListenDucker.sanitizedBundleIDs(
            requested: ["com.spotify.client", "com.apple.Safari"],
            excludingCallApps: [])
        #expect(result == ["com.spotify.client", "com.apple.Safari"])
    }

    @Test("Excludes a bundle ID that's currently a call app")
    func excludesCallApps() {
        let result = ListenDucker.sanitizedBundleIDs(
            requested: ["com.spotify.client", "us.zoom.xos"],
            excludingCallApps: ["us.zoom.xos"])
        #expect(result == ["com.spotify.client"])
    }

    @Test("Excludes Loopbacker's own bundle ID if somehow requested")
    func excludesSelf() {
        // Explicit `ownBundleID`, not relying on `Bundle.main.bundleIdentifier` (nil in a
        // `swift test` host, which isn't a real app bundle).
        let ownID = "com.jacobcoffee.loopbacker"
        let result = ListenDucker.sanitizedBundleIDs(
            requested: ["com.spotify.client", ownID],
            excludingCallApps: [], ownBundleID: ownID)
        #expect(!result.contains(ownID))
        #expect(result.contains("com.spotify.client"))
    }

    @Test("A browser added as an extra call app is excluded from the duck set once it's a call app")
    func userAddedCallAppIsExcluded() {
        // Mirrors CallDuckSettings.extraCallAppBundleIDs: a browser the user marked as "this is
        // a call" should no longer be duckable, even though it isn't in the fixed catalog.
        let result = ListenDucker.sanitizedBundleIDs(
            requested: ["com.google.Chrome", "com.spotify.client"],
            excludingCallApps: ["com.google.Chrome"])
        #expect(result == ["com.spotify.client"])
    }

    @Test("Empty request stays empty")
    func emptyRequestStaysEmpty() {
        #expect(ListenDucker.sanitizedBundleIDs(requested: [], excludingCallApps: ["us.zoom.xos"]).isEmpty)
    }
}
