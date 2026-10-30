import Foundation
import Synchronization
import Testing
@testable import Loopbacker

/// A fake `FXNode` that delays its mono signal by a fixed number of samples (no filtering,
/// no gain change), so tests can tell wet output apart from an undelayed dry signal and verify
/// the chain compensates a stage's own latency when crossfading it in/out.
private final class FakeDelayNode: FXNode, @unchecked Sendable {
    let kind: FXNodeKind = .gate
    let specs: [FXParamSpec] = []
    let params = FXParamStore(specs: [])
    let meters = FXMeters()
    let latencySamples: Int

    private var history: [Float]
    private var writeIndex = 0

    init(latencySamples: Int) {
        self.latencySamples = latencySamples
        history = [Float](repeating: 0, count: max(latencySamples, 1) * 4)
    }

    func process(_ block: FXBlock) {
        for i in 0..<block.frames {
            let x = block.left[i]
            history[writeIndex % history.count] = x
            let readIndex = writeIndex - latencySamples
            block.left[i] = readIndex >= 0 ? history[((readIndex % history.count) + history.count) % history.count] : 0
            writeIndex += 1
        }
        if block.channels == 2 {
            for i in 0..<block.frames { block.right[i] = block.left[i] }
        }
    }

    func reset() {
        writeIndex = 0
        for i in history.indices { history[i] = 0 }
    }
}

/// A fake `FXNode` that leaves audio untouched, for tests only interested in the chain's own
/// swap/crossfade machinery, not any node's DSP.
private final class FakeIdentityNode: FXNode, @unchecked Sendable {
    let kind: FXNodeKind = .limiter
    let specs: [FXParamSpec] = []
    let params = FXParamStore(specs: [])
    let meters = FXMeters()
    let latencySamples = 0
    func process(_ block: FXBlock) {}
    func reset() {}
}

@Suite("FXChain")
struct FXChainTests {
    private static let sampleRate: Float = 48_000

    private func sineInput(frames: Int, freq: Float = 440) -> [Float] {
        (0..<frames).map { sinf(2 * .pi * freq * Float($0) / Self.sampleRate) * 0.5 }
    }

    /// Runs `signal` through a chain with one `FakeDelayNode`, calling `process` once per
    /// `chunkSize` samples (so param-only changes made between calls behave like real
    /// between-block updates), applying `toggleAt` (call index -> desired enabled) along the
    /// way. Returns the processed mono signal.
    private func run(_ signal: [Float], latency: Int, chunkSize: Int,
                     toggleAt: [Int: Bool] = [:]) -> [Float] {
        let chain = FXChain(sampleRate: Self.sampleRate, captureDeviceUID: "test")
        let node = FakeDelayNode(latencySamples: latency)
        let slot = ChainGraph.Slot(id: UUID(), node: node, enabled: true, latency: latency, loadError: nil)
        chain.debugInstallGraph(ChainGraph(slots: [slot]))

        var output: [Float] = []
        output.reserveCapacity(signal.count)
        var offset = 0
        var callIndex = 0
        while offset < signal.count {
            let n = min(chunkSize, signal.count - offset)
            if let wanted = toggleAt[callIndex] { slot.enabled.store(wanted, ordering: .relaxed) }
            var buffer = [Float](repeating: 0, count: n * 2)
            for i in 0..<n { buffer[i * 2] = signal[offset + i]; buffer[i * 2 + 1] = signal[offset + i] }
            buffer.withUnsafeMutableBufferPointer { ptr in
                chain.process(ptr.baseAddress!, frames: n, stride: 2, sampleTime: nil, rawPreNS: nil)
            }
            for i in 0..<n { output.append(buffer[i * 2]) }
            offset += n
            callIndex += 1
        }
        return output
    }

    @Test("Latency-compensated bypass crossfade has no discontinuity")
    func bypassCrossfadeNoDiscontinuity() {
        let latency = 37
        let chunkSize = 64
        let totalFrames = chunkSize * 6
        let signal = sineInput(frames: totalFrames)

        // Reference: node always enabled, never toggled.
        let reference = run(signal, latency: latency, chunkSize: chunkSize)

        // Toggled: flips enabled on and off between blocks. Because the dry tap is delayed by
        // the same `latency` the node itself delays its wet output, bypassing mid-stream reads
        // from exactly where the wet path would be, so the result must match the always-wet
        // reference sample-for-sample (within float rounding) -- any gap in the compensation
        // would show up as a step at a toggle boundary.
        let toggled = run(signal, latency: latency, chunkSize: chunkSize,
                          toggleAt: [1: false, 2: true, 3: false, 4: true])

        #expect(reference.count == toggled.count)
        var maxDiff: Float = 0
        for (a, b) in zip(reference, toggled) { maxDiff = max(maxDiff, abs(a - b)) }
        #expect(maxDiff < 1e-4)
    }

    @Test("Toggling a zero-latency node still crossfades smoothly (no instant jump)")
    func zeroLatencyCrossfadeIsGradual() {
        // A node with no latency whose wet output differs sharply from dry (it inverts the
        // signal), so a crossfade step is actually visible if bypass were instantaneous.
        final class InvertNode: FXNode, @unchecked Sendable {
            let kind: FXNodeKind = .limiter
            let specs: [FXParamSpec] = []
            let params = FXParamStore(specs: [])
            let meters = FXMeters()
            let latencySamples = 0
            func process(_ block: FXBlock) {
                for i in 0..<block.frames { block.left[i] = -block.left[i] }
                if block.channels == 2 { for i in 0..<block.frames { block.right[i] = block.left[i] } }
            }
            func reset() {}
        }

        let chain = FXChain(sampleRate: Self.sampleRate, captureDeviceUID: "test2")
        let node = InvertNode()
        let slot = ChainGraph.Slot(id: UUID(), node: node, enabled: true, latency: 0, loadError: nil)
        chain.debugInstallGraph(ChainGraph(slots: [slot]))

        let frames = 480 // exactly the 10 ms crossfade window at 48 kHz
        var buffer = [Float](repeating: 0.5, count: frames * 2)
        slot.enabled.store(false, ordering: .relaxed)
        buffer.withUnsafeMutableBufferPointer { ptr in
            chain.process(ptr.baseAddress!, frames: frames, stride: 2, sampleTime: nil, rawPreNS: nil)
        }

        // Crossfade from fully wet (-0.5) to fully dry (+0.5) over the block: monotonic, and no
        // single-sample step bigger than the per-sample crossfade rate (1/480 of the 1.0 span).
        var maxStep: Float = 0
        for i in 1..<frames { maxStep = max(maxStep, abs(buffer[i * 2] - buffer[(i - 1) * 2])) }
        #expect(maxStep < 1.0 / 480 + 1e-3)
        #expect(buffer[0] < 0) // starts near fully wet (inverted)
        #expect(buffer[(frames - 1) * 2] > 0) // ends near fully dry
    }

    @Test("A structural graph swap declicks: fade out then fade in, not a jump")
    func graphSwapDeclicks() async {
        let chain = FXChain(sampleRate: Self.sampleRate, captureDeviceUID: "test3")
        // Band-less EQs are exact identities with no latency, so any deviation from `value`
        // below comes from the swap itself.
        let configA = [FXNodeConfig(id: UUID(), kind: .eq, eqBands: [])]
        let configB = [FXNodeConfig(id: UUID(), kind: .eq, eqBands: []), FXNodeConfig(id: UUID(), kind: .eq, eqBands: [])]

        await chain.updateConfigs(configA)

        let frames = 480
        let value: Float = 0.5

        func processBlock() -> [Float] {
            var buffer = [Float](repeating: value, count: frames * 2)
            buffer.withUnsafeMutableBufferPointer { ptr in
                chain.process(ptr.baseAddress!, frames: frames, stride: 2, sampleTime: nil, rawPreNS: nil)
            }
            return stride(from: 0, to: buffer.count, by: 2).map { buffer[$0] }
        }

        // First block settles the initial graph: `value` throughout.
        let steady = processBlock()
        #expect(steady.allSatisfy { abs($0 - value) < 1e-5 })

        // Structural change (different node ids/count) -> next process() call detects the swap.
        await chain.updateConfigs(configB)

        let swapBlock = processBlock() // old graph, faded 1 -> 0 across the block
        #expect(abs(swapBlock.first! - value) < 0.02) // starts near full value
        #expect(swapBlock.last! < 0.05) // ends near silence

        // Monotonically non-increasing (a ramp down, not a jump): no discontinuity.
        for i in 1..<swapBlock.count { #expect(swapBlock[i] <= swapBlock[i - 1] + 1e-4) }

        let fadeInBlock = processBlock() // new graph, faded 0 -> 1 across the block
        #expect(fadeInBlock.first! < 0.05)
        #expect(abs(fadeInBlock.last! - value) < 0.02)
        for i in 1..<fadeInBlock.count { #expect(fadeInBlock[i] >= fadeInBlock[i - 1] - 1e-4) }

        let settled = processBlock()
        #expect(settled.allSatisfy { abs($0 - value) < 1e-5 })
    }

    @Test("Mono (bitwise-identical L/R) input is detected and processed once, not twice")
    func monoDetection() {
        let frames = 32
        var leftBuf = [Float](repeating: 0, count: frames)
        var rightBuf = [Float](repeating: 0, count: frames)
        var interleaved = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Float(i) / Float(frames)
            interleaved[i * 2] = v
            interleaved[i * 2 + 1] = v // mono mic fanned to L+R
        }

        let mono = interleaved.withUnsafeBufferPointer { src in
            leftBuf.withUnsafeMutableBufferPointer { l in
                rightBuf.withUnsafeMutableBufferPointer { r in
                    FXBlockIO.deinterleave(src.baseAddress!, frames: frames, stride: 2,
                                          left: l.baseAddress!, right: r.baseAddress!)
                }
            }
        }
        #expect(mono)
        #expect(leftBuf == (0..<frames).map { Float($0) / Float(frames) })

        // A genuinely stereo signal (channels differ) is reported as not mono.
        var stereoInterleaved = interleaved
        stereoInterleaved[3] = 99 // perturb one R sample
        let stereo = stereoInterleaved.withUnsafeBufferPointer { src in
            leftBuf.withUnsafeMutableBufferPointer { l in
                rightBuf.withUnsafeMutableBufferPointer { r in
                    FXBlockIO.deinterleave(src.baseAddress!, frames: frames, stride: 2,
                                          left: l.baseAddress!, right: r.baseAddress!)
                }
            }
        }
        #expect(!stereo)
    }

    @Test("Master disabled (as AudioRouter wires EffectsPreset.isEnabled == false) settles to output bit-identical to input")
    func masterDisabledSettlesToIdenticalOutput() {
        final class InvertNode: FXNode, @unchecked Sendable {
            let kind: FXNodeKind = .limiter
            let specs: [FXParamSpec] = []
            let params = FXParamStore(specs: [])
            let meters = FXMeters()
            let latencySamples = 0
            func process(_ block: FXBlock) {
                for i in 0..<block.frames { block.left[i] = -block.left[i] }
                if block.channels == 2 { for i in 0..<block.frames { block.right[i] = block.left[i] } }
            }
            func reset() {}
        }

        let chain = FXChain(sampleRate: Self.sampleRate, captureDeviceUID: "master")
        let node = InvertNode()
        let slot = ChainGraph.Slot(id: UUID(), node: node, enabled: true, latency: 0, loadError: nil)
        chain.debugInstallGraph(ChainGraph(slots: [slot]))

        // `FXChain` itself defaults to master-enabled (every pre-existing caller that never
        // touches this API keeps running wet); `AudioRouter.attachFXChain` is the one
        // responsible for applying `EffectsPreset.isEnabled`'s own `false` default, which this
        // simulates explicitly.
        #expect(chain.isMasterEnabled)
        chain.setMasterEnabled(false)

        let frames = 960
        var input = [Float](repeating: 0, count: frames)
        for i in 0..<frames { input[i] = sinf(2 * .pi * 440 * Float(i) / Self.sampleRate) * 0.5 }
        var buffer = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames { buffer[i * 2] = input[i]; buffer[i * 2 + 1] = input[i] }
        buffer.withUnsafeMutableBufferPointer { ptr in
            chain.process(ptr.baseAddress!, frames: frames, stride: 2, sampleTime: nil, rawPreNS: nil)
        }
        // Ramps down from fully wet over the first 480 samples (10 ms crossfade); the tail is
        // fully settled dry.
        for i in (frames - 100)..<frames {
            #expect(abs(buffer[i * 2] - input[i]) < 1e-5, "sample \(i): expected bit-identical dry passthrough while master disabled")
        }

        // Re-enabling flips the chain back to wet (inverted); give it another settle window.
        chain.setMasterEnabled(true)
        var buffer2 = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames { buffer2[i * 2] = input[i]; buffer2[i * 2 + 1] = input[i] }
        buffer2.withUnsafeMutableBufferPointer { ptr in
            chain.process(ptr.baseAddress!, frames: frames, stride: 2, sampleTime: nil, rawPreNS: nil)
        }
        for i in (frames - 100)..<frames {
            #expect(abs(buffer2[i * 2] - (-input[i])) < 1e-5, "sample \(i): expected wet (inverted) output once master is re-enabled")
        }
    }

    @Test("Effects off adds no latency and stops running stages; turning back on resumes wet")
    func masterDisabledSkipsGraphWithoutLatency() {
        final class CountingDelayNode: FXNode, @unchecked Sendable {
            let kind: FXNodeKind = .limiter
            let specs: [FXParamSpec] = []
            let params = FXParamStore(specs: [])
            let meters = FXMeters()
            let latencySamples = 64
            var processCalls = 0
            private var ring = [Float](repeating: 0, count: 64)
            private var pos = 0
            func process(_ block: FXBlock) {
                processCalls += 1
                for i in 0..<block.frames {
                    let out = ring[pos]
                    ring[pos] = block.left[i]
                    pos = (pos + 1) % ring.count
                    block.left[i] = out
                }
                if block.channels == 2 { for i in 0..<block.frames { block.right[i] = block.left[i] } }
            }
            func reset() { ring = [Float](repeating: 0, count: 64); pos = 0 }
        }

        let chain = FXChain(sampleRate: Self.sampleRate, captureDeviceUID: "master-idle")
        let node = CountingDelayNode()
        chain.debugInstallGraph(ChainGraph(slots: [
            ChainGraph.Slot(id: UUID(), node: node, enabled: true, latency: node.latencySamples, loadError: nil)
        ]))
        chain.setMasterEnabled(false)

        let frames = 480
        func run(_ phase: Int) -> (input: [Float], output: [Float]) {
            var input = [Float](repeating: 0, count: frames)
            for i in 0..<frames { input[i] = sinf(2 * .pi * 440 * Float(phase * frames + i) / Self.sampleRate) * 0.5 }
            var buffer = [Float](repeating: 0, count: frames * 2)
            for i in 0..<frames { buffer[i * 2] = input[i]; buffer[i * 2 + 1] = input[i] }
            buffer.withUnsafeMutableBufferPointer {
                chain.process($0.baseAddress!, frames: frames, stride: 2, sampleTime: nil, rawPreNS: nil)
            }
            return (input, stride(from: 0, to: frames * 2, by: 2).map { buffer[$0] })
        }

        _ = run(0) // the 10 ms fade from wet to the undelayed input
        let callsAfterFade = node.processCalls
        for phase in 1...4 {
            let (input, output) = run(phase)
            #expect(output == input, "effects off must pass input through with no delay")
        }
        #expect(node.processCalls == callsAfterFade, "stages must not run while effects are off")

        chain.setMasterEnabled(true)
        _ = run(5) // fade back in while the stage re-primes
        let (input, output) = run(6)
        for i in node.latencySamples..<frames {
            #expect(abs(output[i] - input[i - node.latencySamples]) < 1e-5, "sample \(i): expected the stage's delayed (wet) output")
        }
    }

    @Test("A/B bypass applies the measured output/input loudness ratio to the dry path, not a frozen unity")
    func abBypassAppliesMeasuredRatio() async {
        final class GainNode: FXNode, @unchecked Sendable {
            let kind: FXNodeKind = .limiter
            let specs: [FXParamSpec] = []
            let params = FXParamStore(specs: [])
            let meters = FXMeters()
            let latencySamples = 0
            let gain: Float
            init(gain: Float) { self.gain = gain }
            func process(_ block: FXBlock) {
                for i in 0..<block.frames { block.left[i] *= gain }
                if block.channels == 2 { for i in 0..<block.frames { block.right[i] = block.left[i] } }
            }
            func reset() {}
        }

        let gain: Float = 3.0
        let chain = FXChain(sampleRate: Self.sampleRate, captureDeviceUID: "ab-ratio")
        let node = GainNode(gain: gain)
        let slot = ChainGraph.Slot(id: UUID(), node: node, enabled: true, latency: 0, loadError: nil)
        chain.debugInstallGraph(ChainGraph(slots: [slot]))

        let voice = SyntheticVoiceGenerator.generate(sampleRate: Self.sampleRate, speechPeakDBFS: -20)

        @discardableResult
        func runOnce(collectOutput: Bool) -> [Float] {
            var output = [Float](repeating: 0, count: collectOutput ? voice.samples.count : 0)
            var offset = 0
            let chunk = 480
            while offset < voice.samples.count {
                let n = min(chunk, voice.samples.count - offset)
                var buffer = [Float](repeating: 0, count: n * 2)
                for i in 0..<n { buffer[i * 2] = voice.samples[offset + i]; buffer[i * 2 + 1] = voice.samples[offset + i] }
                buffer.withUnsafeMutableBufferPointer { ptr in
                    chain.process(ptr.baseAddress!, frames: n, stride: 2, sampleTime: nil, rawPreNS: nil)
                }
                if collectOutput { for i in 0..<n { output[offset + i] = buffer[i * 2] } }
                offset += n
            }
            return output
        }

        // Let the measured ratio converge while enabled (not bypassed): two passes give the
        // 0.5 s smoothing time constant well over an order of magnitude more cumulative voiced
        // time than it needs.
        runOnce(collectOutput: false)
        runOnce(collectOutput: false)

        chain.setABBypass(true)
        let bypassed = runOnce(collectOutput: true) // the 10 ms A/B crossfade settles almost immediately

        func rms(_ xs: [Float], ranges: [Range<Int>]) -> Float {
            var sum: Float = 0
            var count = 0
            for r in ranges { for i in r { sum += xs[i] * xs[i]; count += 1 } }
            return count > 0 ? sqrtf(sum / Float(count)) : 0
        }

        let inRMS = rms(voice.samples, ranges: voice.steadyStateSpeechRanges)
        let outRMS = rms(bypassed, ranges: voice.steadyStateSpeechRanges)
        let ratio = outRMS / inRMS

        // A frozen ratio of 1 (the bug) would put this at 1.0; the fix should land close to the
        // node's actual 3x gain.
        #expect(ratio > 2.0, "A/B-bypassed output/input ratio \(ratio) should track the measured ~\(gain)x gain, not stay near 1")
    }

    @Test("A settled-bypassed stage skips node.process, and re-enabling a latent node has no output discontinuity")
    func settledBypassSkipsProcessingAndReenableHasNoDiscontinuity() {
        final class CountingInvertDelayNode: FXNode, @unchecked Sendable {
            let kind: FXNodeKind = .gate
            let specs: [FXParamSpec] = []
            let params = FXParamStore(specs: [])
            let meters = FXMeters()
            let latencySamples: Int
            private(set) var processCallCount = 0
            private(set) var resetCallCount = 0
            private var history: [Float]
            private var writeIndex = 0

            init(latencySamples: Int) {
                self.latencySamples = latencySamples
                history = [Float](repeating: 0, count: max(latencySamples, 1) * 4)
            }

            func process(_ block: FXBlock) {
                processCallCount += 1
                for i in 0..<block.frames {
                    let x = block.left[i]
                    history[writeIndex % history.count] = x
                    let readIndex = writeIndex - latencySamples
                    let delayed = readIndex >= 0 ? history[((readIndex % history.count) + history.count) % history.count] : 0
                    block.left[i] = -delayed
                    writeIndex += 1
                }
                if block.channels == 2 { for i in 0..<block.frames { block.right[i] = block.left[i] } }
            }

            func reset() {
                resetCallCount += 1
                writeIndex = 0
                for i in history.indices { history[i] = 0 }
            }
        }

        let latency = 37
        let node = CountingInvertDelayNode(latencySamples: latency)
        let chain = FXChain(sampleRate: Self.sampleRate, captureDeviceUID: "settled-bypass")
        let slot = ChainGraph.Slot(id: UUID(), node: node, enabled: true, latency: latency, loadError: nil)
        chain.debugInstallGraph(ChainGraph(slots: [slot]))

        let value: Float = 0.5
        func processBlock(_ frames: Int) -> [Float] {
            var buffer = [Float](repeating: value, count: frames * 2)
            buffer.withUnsafeMutableBufferPointer { ptr in
                chain.process(ptr.baseAddress!, frames: frames, stride: 2, sampleTime: nil, rawPreNS: nil)
            }
            return stride(from: 0, to: buffer.count, by: 2).map { buffer[$0] }
        }

        // Warm up enabled: the node runs and its wet (inverted-delayed) output settles in.
        _ = processBlock(600)
        #expect(node.processCallCount > 0)

        // Disable and run past the 10 ms crossfade so the stage settles fully bypassed by the
        // end of this call.
        slot.enabled.store(false, ordering: .relaxed)
        let settleOut = processBlock(600)
        #expect(settleOut.suffix(100).allSatisfy { abs($0 - value) < 1e-4 })
        let countAfterSettle = node.processCallCount

        // Already settled off before this call starts: must skip `node.process` for its entire
        // duration and emit pure delayed dry throughout.
        let stillOff = processBlock(600)
        #expect(node.processCallCount == countAfterSettle, "a settled bypassed stage must skip node.process")
        #expect(stillOff.allSatisfy { abs($0 - value) < 1e-4 })

        // Re-enable: must reset exactly once, and the output stream (settled-off -> priming ->
        // crossfade-in) must never jump by more than one crossfade step at a time, despite the
        // node's own history having been skipped (stale/zeroed) while it was off.
        slot.enabled.store(true, ordering: .relaxed)
        var allSamples: [Float] = []
        for _ in 0..<4 { allSamples += processBlock(480) }

        #expect(node.resetCallCount == 1, "re-enabling a settled-off stage must reset its history exactly once")

        var maxStep: Float = 0
        for i in 1..<allSamples.count { maxStep = max(maxStep, abs(allSamples[i] - allSamples[i - 1])) }
        #expect(maxStep < 1.0 / 480 + 1e-3, "re-enable produced a discontinuity bigger than one crossfade step: \(maxStep)")

        // Eventually settles back to fully wet (inverted dry): -value.
        #expect(abs(allSamples.last! - (-value)) < 1e-3)
    }
}
