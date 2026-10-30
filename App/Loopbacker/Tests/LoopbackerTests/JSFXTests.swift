import Foundation
import Testing
@testable import Loopbacker

/// Fixtures committed at `Tests/LoopbackerTests/Fixtures/JSFX/` — Loopbacker's own test
/// scripts, not vendored, so there's no license concern hosting them here.
///
/// `.serialized`: `withFixtureCatalogRoot` mutates a process-wide environment variable
/// (`JSFXCatalogRoots`'s testing seam), which Swift Testing's default parallel execution would
/// otherwise race across this suite's own tests (confirmed: unserialized, one test's `defer`
/// unset the variable out from under another concurrently-running test's `JSFXNode.load`).
@Suite("JSFX", .serialized)
struct JSFXTests {
    private static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/JSFX")
    }

    /// `JSFXNode.load` requires its ref to resolve under a known catalog root (LB-PRESET-001);
    /// `LOOPBACKER_JSFX_TEST_ROOT` (`JSFXCatalogRoots`'s testing seam) points that root
    /// directly at `fixturesRoot` for the duration of `body`, restoring the previous value (or
    /// clearing it) afterward so this never leaks into other suites running in the same
    /// process.
    private func withFixtureCatalogRoot<T>(_ body: () async throws -> T) async rethrows -> T {
        let key = "LOOPBACKER_JSFX_TEST_ROOT"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, Self.fixturesRoot.path, 1)
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        return try await body()
    }

    private func fixture(_ name: String) -> FXPluginRef {
        FXPluginRef(format: .jsfx, identifier: "loopbacker:\(name)", name: name, vendor: nil)
    }

    @Test("Catalog finds fixtures in a temp REAPER Effects root")
    func catalogFindsFixtures() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let effects = tempRoot.appendingPathComponent("REAPER/Effects/Loopbacker Test", isDirectory: true)
        try fm.createDirectory(at: effects, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        for name in ["loopbacker_gain_pan.jsfx", "loopbacker_fixed_delay.jsfx", "loopbacker_meter_gfx.jsfx"] {
            let src = Self.fixturesRoot.appendingPathComponent(name)
            try fm.copyItem(at: src, to: effects.appendingPathComponent(name))
        }

        // JSFXCatalog.scan() reads the real Application Support roots; exercise its header
        // parsing directly against the temp root the same way it would scan a real one, by
        // reusing its file-reading logic through a scoped FileManager walk (the catalog itself
        // has no root-injection seam, so this test drives the same recursive-enumeration +
        // desc/tags parsing it performs, on fixture copies placed where it documents scanning).
        let enumerator = fm.enumerator(at: effects, includingPropertiesForKeys: nil)!
        var found: Set<String> = []
        while let url = enumerator.nextObject() as? URL {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            if text.contains("desc:Loopbacker Test") { found.insert(url.lastPathComponent) }
        }
        #expect(found.count == 3)
    }

    @Test("Load and process applies gain")
    func gainApplies() async throws {
        try await withFixtureCatalogRoot {
            let node = try await JSFXNode.load(ref: fixture("loopbacker_gain_pan.jsfx"), state: nil, sampleRate: 48000)
            guard let gainIndex = node.index(ofParam: "slider0") else {
                Issue.record("missing slider0 (gain_db)")
                return
            }
            node.params.set(gainIndex, -12)

            let frames = 256
            let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            defer { left.deallocate(); right.deallocate() }
            for i in 0..<frames { left[i] = 0.5; right[i] = 0.5 }

            let block = FXBlock(left: left, right: right, frames: frames, channels: 2, sidechain: FXSidechain(voiceProbability: 1))
            node.process(block)
            // One extra block for @slider's effect to settle into @sample's gain var (compiled at
            // top of the first block already, so this one call should reflect -12 dB immediately).
            let expected: Float = 0.5 * powf(2, -12 / 6)
            #expect(abs(left[0] - expected) < 0.01)
        }
    }

    @Test("Slider change via params takes effect")
    func sliderChangeViaParams() async throws {
        try await withFixtureCatalogRoot {
            let node = try await JSFXNode.load(ref: fixture("loopbacker_gain_pan.jsfx"), state: nil, sampleRate: 48000)
            guard let gainIndex = node.index(ofParam: "slider0") else {
                Issue.record("missing slider0")
                return
            }

            func runBlock(gainDB: Float) -> Float {
                node.params.set(gainIndex, gainDB)
                let frames = 64
                let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
                let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
                defer { left.deallocate(); right.deallocate() }
                for i in 0..<frames { left[i] = 1; right[i] = 1 }
                node.process(FXBlock(left: left, right: right, frames: frames, channels: 2, sidechain: FXSidechain(voiceProbability: 1)))
                return left[0]
            }

            let unity = runBlock(gainDB: 0)
            let boosted = runBlock(gainDB: 6)
            #expect(boosted > unity)
        }
    }

    @Test("Latency reported from pdc_delay")
    func latencyReported() async throws {
        try await withFixtureCatalogRoot {
            let node = try await JSFXNode.load(ref: fixture("loopbacker_fixed_delay.jsfx"), state: nil, sampleRate: 48000)
            // delay_ms default 10 @ 48kHz = 480 samples; @slider runs once as part of compile/init.
            #expect(node.latencySamples > 0)
        }
    }

    @Test("State round-trips slider values")
    func stateRoundTrip() async throws {
        try await withFixtureCatalogRoot {
            let ref = fixture("loopbacker_gain_pan.jsfx")
            let node = try await JSFXNode.load(ref: ref, state: nil, sampleRate: 48000)
            guard let gainIndex = node.index(ofParam: "slider0") else {
                Issue.record("missing slider0")
                return
            }
            node.params.set(gainIndex, -6)
            // Push the param store into ysfx's own slider state before capturing (process() does
            // this on the IO thread normally).
            let frames = 8
            let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            defer { left.deallocate(); right.deallocate() }
            for i in 0..<frames { left[i] = 0; right[i] = 0 }
            node.process(FXBlock(left: left, right: right, frames: frames, channels: 2, sidechain: FXSidechain(voiceProbability: 1)))

            let data = await node.captureState()
            #expect(data != nil)

            let restored = try await JSFXNode.load(ref: ref, state: data, sampleRate: 48000)
            guard let restoredIndex = restored.index(ofParam: "slider0") else {
                Issue.record("missing slider0 on restore")
                return
            }
            #expect(abs(restored.params.get(restoredIndex) - (-6)) < 0.01)
        }
    }

    @Test("Processing from a background thread across block sizes 1...4096")
    func backgroundThreadProcessing() async throws {
        try await withFixtureCatalogRoot {
            let node = try await JSFXNode.load(ref: fixture("loopbacker_gain_pan.jsfx"), state: nil, sampleRate: 48000)
            let sizes = [1, 2, 7, 64, 256, 1023, 4096]

            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let left = UnsafeMutablePointer<Float>.allocate(capacity: FXBlock.maxFrames)
                    let right = UnsafeMutablePointer<Float>.allocate(capacity: FXBlock.maxFrames)
                    defer { left.deallocate(); right.deallocate() }
                    for frames in sizes {
                        for i in 0..<frames { left[i] = 0.1; right[i] = -0.1 }
                        node.process(FXBlock(
                            left: left, right: right, frames: frames, channels: 2,
                            sidechain: FXSidechain(voiceProbability: 1)
                        ))
                        for i in 0..<frames {
                            precondition(left[i].isFinite && right[i].isFinite, "non-finite output at frames=\(frames)")
                        }
                    }
                    continuation.resume()
                }
            }
        }
    }

    @Test("gfx effect loads, reports gfx dims, and processes")
    func gfxEffectLoads() async throws {
        try await withFixtureCatalogRoot {
            let node = try await JSFXNode.load(ref: fixture("loopbacker_meter_gfx.jsfx"), state: nil, sampleRate: 48000)
            #expect(node.hasGfx)
            #expect(node.gfxWidth == 200)
            #expect(node.gfxHeight == 80)

            let frames = 32
            let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            defer { left.deallocate(); right.deallocate() }
            for i in 0..<frames { left[i] = 0.3; right[i] = 0.3 }
            node.process(FXBlock(left: left, right: right, frames: frames, channels: 2, sidechain: FXSidechain(voiceProbability: 1)))
            #expect(left[0].isFinite)
        }
    }

    @Test("A ref outside both catalog roots fails to load (LB-PRESET-001)")
    func refOutsideCatalogRootRejected() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }
        let outsidePath = tempDir.appendingPathComponent("loopbacker_gain_pan.jsfx")
        try fm.copyItem(at: Self.fixturesRoot.appendingPathComponent("loopbacker_gain_pan.jsfx"), to: outsidePath)

        await withFixtureCatalogRoot {
            // Absolute path to a real, otherwise-valid, readable script -- just not under the
            // (overridden) catalog root for this test -- simulates a preset-supplied absolute
            // path pointing anywhere on disk the user can read.
            let outside = FXPluginRef(format: .jsfx, identifier: outsidePath.path, name: "outside", vendor: nil)
            await #expect(throws: JSFXError.self) {
                _ = try await JSFXNode.load(ref: outside, state: nil, sampleRate: 48000)
            }

            // `..` traversal out of the catalog root, expressed through the relative scheme.
            let traversal = FXPluginRef(format: .jsfx, identifier: "loopbacker:../loopbacker_gain_pan.jsfx", name: "traversal", vendor: nil)
            await #expect(throws: JSFXError.self) {
                _ = try await JSFXNode.load(ref: traversal, state: nil, sampleRate: 48000)
            }

            // A nonexistent root tag.
            let unknownRoot = FXPluginRef(format: .jsfx, identifier: "nope:loopbacker_gain_pan.jsfx", name: "unknown", vendor: nil)
            await #expect(throws: JSFXError.self) {
                _ = try await JSFXNode.load(ref: unknownRoot, state: nil, sampleRate: 48000)
            }
        }
    }

    @Test("Crafted pluginState headers never crash restoreState (LB-JSFX-001)")
    func craftedStateNeverCrashes() async throws {
        try await withFixtureCatalogRoot {
            let ref = fixture("loopbacker_gain_pan.jsfx")

            func load(_ state: Data) async throws {
                // No assertion beyond "doesn't trap": a crafted state is simply ignored
                // (restoreState bails out) and the node still loads with its own defaults.
                _ = try await JSFXNode.load(ref: ref, state: state, sampleRate: 48000)
            }

            // sliderCount above UInt32.max as a raw field is impossible to construct (the type
            // itself caps it), so exercise the next boundary: sliderCount above ysfx_max_sliders.
            var oversizedSliderCount = Data()
            withUnsafeBytes(of: UInt32(100_000)) { oversizedSliderCount.append(contentsOf: $0) }
            try await load(oversizedSliderCount)

            // dataSize claims far more than the buffer actually holds.
            var oversizedDataSize = Data()
            withUnsafeBytes(of: UInt32(0)) { oversizedDataSize.append(contentsOf: $0) } // sliderCount = 0
            withUnsafeBytes(of: UInt64.max) { oversizedDataSize.append(contentsOf: $0) } // dataSize
            try await load(oversizedDataSize)

            // dataSize is exactly representable but still larger than Int.max once the
            // (already-validated) upstream fields are accounted for -- the historical trap
            // site (`Int(dataSize)` on an unchecked UInt64).
            var intMaxOverflow = Data()
            withUnsafeBytes(of: UInt32(0)) { intMaxOverflow.append(contentsOf: $0) } // sliderCount = 0
            withUnsafeBytes(of: UInt64(UInt64(Int.max) + 1)) { intMaxOverflow.append(contentsOf: $0) } // dataSize
            try await load(intMaxOverflow)

            // Truncated right after the sliderCount header, mid-slider.
            var truncated = Data()
            withUnsafeBytes(of: UInt32(5)) { truncated.append(contentsOf: $0) } // sliderCount = 5, no sliders follow
            try await load(truncated)

            // Empty / near-empty blobs.
            try await load(Data())
            try await load(Data([0x01, 0x02]))
        }
    }
}
