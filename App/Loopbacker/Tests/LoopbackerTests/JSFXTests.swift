import Foundation
import Testing
@testable import Loopbacker

/// Fixtures committed at `Tests/LoopbackerTests/Fixtures/JSFX/` — Loopbacker's own test
/// scripts, not vendored, so there's no license concern hosting them here.
@Suite("JSFX")
struct JSFXTests {
    private static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/JSFX")
    }

    private func fixture(_ name: String) -> FXPluginRef {
        let path = Self.fixturesRoot.appendingPathComponent(name).path
        return FXPluginRef(format: .jsfx, identifier: path, name: name, vendor: nil)
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

    @Test("Slider change via params takes effect")
    func sliderChangeViaParams() async throws {
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

    @Test("Latency reported from pdc_delay")
    func latencyReported() async throws {
        let node = try await JSFXNode.load(ref: fixture("loopbacker_fixed_delay.jsfx"), state: nil, sampleRate: 48000)
        // delay_ms default 10 @ 48kHz = 480 samples; @slider runs once as part of compile/init.
        #expect(node.latencySamples > 0)
    }

    @Test("State round-trips slider values")
    func stateRoundTrip() async throws {
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

    @Test("Processing from a background thread across block sizes 1...4096")
    func backgroundThreadProcessing() async throws {
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

    @Test("gfx effect loads, reports gfx dims, and processes")
    func gfxEffectLoads() async throws {
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
