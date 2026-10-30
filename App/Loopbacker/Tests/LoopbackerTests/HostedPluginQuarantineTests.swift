import Foundation
import Testing
@testable import Loopbacker

/// Exercises `HostedPluginQuarantine` against a temp directory (its `init(directory:)` testing
/// seam), never `HostedPluginQuarantine.shared` -- the real singleton reads and writes
/// `~/Library/Application Support/Loopbacker/crash-sentinels`, which the installed, running app
/// on this machine may also be using.
@Suite("HostedPluginQuarantine")
struct HostedPluginQuarantineTests {
    private func makeRef(_ name: String = "Test") -> FXPluginRef {
        FXPluginRef(format: .jsfx, identifier: "loopbacker:test.jsfx", name: name, vendor: nil)
    }

    private func withTempDirectory<T>(_ body: (URL) async throws -> T) async rethrows -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }

    private func sentinelExists(_ nodeID: UUID, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(nodeID.uuidString + ".json").path)
    }

    /// Polls `condition` (expected to eventually become true via the shared sweep, which ticks
    /// every 250 ms) instead of a fixed sleep. Bounded at ~4 s.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<40 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    @Test("A sentinel left over from a previous launch is reported as quarantined")
    func leftoverSentinelIsQuarantined() async {
        await withTempDirectory { dir in
            let nodeID = UUID()
            let session1 = HostedPluginQuarantine(directory: dir)
            session1.beginTracking(nodeID: nodeID, ref: makeRef())
            // No clear call at all: simulates a crash before the node ever rendered or was
            // torn down.

            // Simulated relaunch: a fresh instance over the same directory re-reads whatever
            // sentinels are still on disk, exactly like `HostedPluginQuarantine.shared`'s
            // `init` does at real app launch.
            let session2 = HostedPluginQuarantine(directory: dir)
            #expect(session2.isQuarantined(nodeID: nodeID))
            #expect(session2.quarantinedEntries.contains { $0.nodeID == nodeID })
        }
    }

    @Test("clearSessionSentinels on clean termination leaves nothing quarantined, even for a node that never rendered")
    func cleanTerminationClearsEverything() async {
        await withTempDirectory { dir in
            let nodeID = UUID()
            let session1 = HostedPluginQuarantine(directory: dir)
            session1.beginTracking(nodeID: nodeID, ref: makeRef())
            // Node never rendered and was never torn down -- simulates it still being live
            // right up to quit, the case `applicationWillTerminate` covers.
            session1.clearSessionSentinels()
            #expect(!sentinelExists(nodeID, in: dir))

            let session2 = HostedPluginQuarantine(directory: dir)
            #expect(!session2.isQuarantined(nodeID: nodeID))
        }
    }

    /// A trivial `HostedRenderWitness` the test controls directly, standing in for the private
    /// `QuarantineWitnessNode` (`FXNodeFactory.swift`).
    private final class FakeWitness: HostedRenderWitness {
        var hasRendered = false
    }

    @Test("A witness deallocated without ever rendering clears its own sentinel (not a crash)")
    func deallocatedWithoutRenderingClears() async {
        await withTempDirectory { dir in
            let nodeID = UUID()
            let session = HostedPluginQuarantine(directory: dir)
            session.beginTracking(nodeID: nodeID, ref: makeRef())

            do {
                let witness = FakeWitness()
                session.observe(nodeID: nodeID, witness: witness)
                // `witness` goes out of scope here without ever setting `hasRendered = true`:
                // simulates a disabled slot, a chain torn down for a route change, or any other
                // normal removal -- not a crash, since the sweep reaching this node at all
                // proves the process is still alive.
            }

            await waitUntil { !sentinelExists(nodeID, in: dir) }
            #expect(!sentinelExists(nodeID, in: dir))

            let relaunch = HostedPluginQuarantine(directory: dir)
            #expect(!relaunch.isQuarantined(nodeID: nodeID))
        }
    }

    @Test("A witness that renders clears its sentinel via the shared sweep")
    func renderedWitnessClears() async {
        await withTempDirectory { dir in
            let nodeID = UUID()
            let session = HostedPluginQuarantine(directory: dir)
            session.beginTracking(nodeID: nodeID, ref: makeRef())

            let witness = FakeWitness()
            session.observe(nodeID: nodeID, witness: witness)
            witness.hasRendered = true

            await waitUntil { !sentinelExists(nodeID, in: dir) }
            #expect(!sentinelExists(nodeID, in: dir))
            withExtendedLifetime(witness) {}

            let relaunch = HostedPluginQuarantine(directory: dir)
            #expect(!relaunch.isQuarantined(nodeID: nodeID))
        }
    }

    @Test("retry clears a quarantined node so a relaunch no longer reports it")
    func retryClears() async {
        await withTempDirectory { dir in
            let nodeID = UUID()
            let session1 = HostedPluginQuarantine(directory: dir)
            session1.beginTracking(nodeID: nodeID, ref: makeRef())

            let session2 = HostedPluginQuarantine(directory: dir)
            #expect(session2.isQuarantined(nodeID: nodeID))
            session2.retry(nodeID: nodeID)
            #expect(!session2.isQuarantined(nodeID: nodeID))

            let session3 = HostedPluginQuarantine(directory: dir)
            #expect(!session3.isQuarantined(nodeID: nodeID))
        }
    }
}
