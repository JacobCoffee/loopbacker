import Foundation
import Testing
@testable import Loopbacker

/// Apple's own effect Audio Units: always installed, so these tests don't depend on anything
/// the maintainer happens to have. Identifiers are `"type subtype manufacturer"` FourCCs.
private enum BuiltIn {
    static let delay = FXPluginRef(format: .audioUnit, identifier: "aufx dely appl", name: "AUDelay", vendor: "Apple")
    static let nBandEQ = FXPluginRef(format: .audioUnit, identifier: "aufx nbeq appl", name: "AUNBandEQ", vendor: "Apple")
    static let peakLimiter = FXPluginRef(format: .audioUnit, identifier: "aufx lmtr appl", name: "AUPeakLimiter", vendor: "Apple")
    static let dynamicsProcessor = FXPluginRef(format: .audioUnit, identifier: "aufx dcmp appl", name: "AUDynamicsProcessor", vendor: "Apple")
}

private let sampleRate: Double = 48_000

/// Fills `node`'s stereo pair with `generate(frame)` and runs one `process` call, returning the
/// output in a fresh pair of arrays. `channels` lets a test exercise the node's mono/stereo
/// channel-adapting paths.
@discardableResult
private func render(_ node: AUHostNode, frames: Int, channels: Int = 2, _ generate: (Int) -> Float = { _ in 0 }) -> (left: [Float], right: [Float]) {
    var left = (0..<frames).map(generate)
    var right = channels == 2 ? (0..<frames).map(generate) : left
    left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
            let block = FXBlock(left: l.baseAddress!, right: r.baseAddress!, frames: frames, channels: channels,
                                 sidechain: FXSidechain(voiceProbability: 1))
            node.process(block)
        }
    }
    return (left, right)
}

private func paramIndex(_ node: AUHostNode, named name: String) throws -> Int {
    try #require(node.specs.firstIndex { $0.name == name })
}

private func sineWave(frequency: Float, amplitude: Float, frame: Int) -> Float {
    amplitude * sinf(2 * .pi * frequency * Float(frame) / Float(sampleRate))
}

@Suite("AUCatalog")
struct AUCatalogTests {
    @Test("Finds Apple's built-in effect Audio Units")
    func findsBuiltins() async {
        let plugins = await AUCatalog.scan()
        let identifiers = Set(plugins.map(\.ref.identifier))
        #expect(identifiers.contains(BuiltIn.delay.identifier))
        #expect(identifiers.contains(BuiltIn.nBandEQ.identifier))
        #expect(identifiers.contains(BuiltIn.peakLimiter.identifier))
        #expect(identifiers.contains(BuiltIn.dynamicsProcessor.identifier))
    }

    @Test("Reports vendor on the ref and AUv3-ness on the info")
    func metadata() async throws {
        let plugins = await AUCatalog.scan()
        let delay = try #require(plugins.first { $0.ref.identifier == BuiltIn.delay.identifier })
        #expect(delay.ref.vendor == "Apple")
        #expect(delay.isAUv3 == false)
    }
}

@Suite("AUHostNode")
struct AUHostNodeTests {
    @Test("Loads a built-in AU and exposes its parameters as specs")
    func loadsAndExposesSpecs() async throws {
        let node = try await AUHostNode.load(ref: BuiltIn.delay, state: nil, sampleRate: sampleRate)
        #expect(node.specs.count == 4)
        #expect(node.specs.contains { $0.name == "Delay Time" })
        #expect(node.specs.allSatisfy { $0.hostAddress != nil })
    }

    @Test("An impulse comes out shifted by the delay time")
    func delayShiftsSignal() async throws {
        let node = try await AUHostNode.load(ref: BuiltIn.delay, state: nil, sampleRate: sampleRate)
        node.params.set(try paramIndex(node, named: "Dry/Wet Mix"), 100)      // fully wet: no t=0 dry impulse
        node.params.set(try paramIndex(node, named: "Feedback"), 0)          // one echo, not a train
        node.params.set(try paramIndex(node, named: "Lowpass Cutoff Frequency"), 22_050) // least smearing
        let delaySeconds: Float = 0.02
        node.params.set(try paramIndex(node, named: "Delay Time"), delaySeconds)
        let expectedFrame = Int(delaySeconds * Float(sampleRate))

        let frames = 4096
        let output = render(node, frames: frames) { $0 == 0 ? 1 : 0 }

        let peakIndex = output.left.indices.max { abs(output.left[$0]) < abs(output.left[$1]) }!
        #expect(abs(peakIndex - expectedFrame) <= 20)
        #expect(abs(output.left[0]) < abs(output.left[peakIndex]))
    }

    @Test("A loud sine comes out capped near 0 dBFS")
    func limiterCapsLevel() async throws {
        let node = try await AUHostNode.load(ref: BuiltIn.peakLimiter, state: nil, sampleRate: sampleRate)
        let frames = 4096
        let input = render(node, frames: frames) { sineWave(frequency: 440, amplitude: 4, frame: $0) }
        _ = input // the limiter needs a block to ramp in; measure the next one, fully limited
        let output = render(node, frames: frames) { sineWave(frequency: 440, amplitude: 4, frame: $0 + frames) }
        let inputPeak: Float = 4
        let outputPeak = output.left.reduce(0) { max($0, abs($1)) }
        #expect(outputPeak < inputPeak)
        #expect(outputPeak < 1.2) // a peak limiter's job: hold near 0 dBFS even when driven at +12 dB
        #expect(output.left.allSatisfy { $0.isFinite })
    }

    @Test("Parameter writes through `params` reach the plugin's audio")
    func paramWritesTakeEffect() async throws {
        // Two fresh nodes, not one mid-stream change: AUNBandEQ's gain has a multi-block
        // internal settling time (its reported `latency` doesn't cover it), which would make
        // this flaky. A parameter set before the first block always applies to that block.
        let quietNode = try await AUHostNode.load(ref: BuiltIn.peakLimiter, state: nil, sampleRate: sampleRate)
        let loudNode = try await AUHostNode.load(ref: BuiltIn.peakLimiter, state: nil, sampleRate: sampleRate)
        loudNode.params.set(try paramIndex(loudNode, named: "Pre-Gain"), 24) // +24 dB drive

        let frames = 2048
        let quiet = render(quietNode, frames: frames) { sineWave(frequency: 1000, amplitude: 0.05, frame: $0) }
        let loud = render(loudNode, frames: frames) { sineWave(frequency: 1000, amplitude: 0.05, frame: $0) }
        let quietPeak = quiet.left.reduce(0) { max($0, abs($1)) }
        let loudPeak = loud.left.reduce(0) { max($0, abs($1)) }

        #expect(loudPeak > quietPeak * 2)
    }

    @Test("State round-trips a changed parameter")
    func stateRoundTrips() async throws {
        let node = try await AUHostNode.load(ref: BuiltIn.delay, state: nil, sampleRate: sampleRate)
        let feedbackIndex = try paramIndex(node, named: "Feedback")
        node.params.set(feedbackIndex, 42)
        render(node, frames: 256) // let the AU actually apply the scheduled change
        let state = await MainActor.run { node.captureState() }
        let restored = try #require(state)

        let reloaded = try await AUHostNode.load(ref: BuiltIn.delay, state: restored, sampleRate: sampleRate)
        let reloadedFeedbackIndex = try paramIndex(reloaded, named: "Feedback")
        #expect(abs(reloaded.params.get(reloadedFeedbackIndex) - 42) < 0.01)
    }

    @Test("Reports nonzero latency for the peak limiter")
    func latencyReported() async throws {
        let node = try await AUHostNode.load(ref: BuiltIn.peakLimiter, state: nil, sampleRate: sampleRate)
        #expect(node.latencySamples > 0)
    }

    @Test("Processes block sizes 1...4096 on one instance, in increasing and random order, with no render errors")
    func variedBlockSizesOffMainThread() async throws {
        let node = try await AUHostNode.load(ref: BuiltIn.delay, state: nil, sampleRate: sampleRate)
        node.params.set(try paramIndex(node, named: "Dry/Wet Mix"), 0) // pure dry: output must equal input exactly
        let increasing = [1, 2, 3, 7, 32, 63, 64, 127, 128, 255, 256, 511, 1023, 2047, 4095, 4096]
        // Deterministic shuffle (xorshift), so a HAL-style jump from a small block straight to
        // a large one is exercised too, not just a monotonic ramp.
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        func nextIndex(_ bound: Int) -> Int {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(bound))
        }
        var random = increasing
        for i in stride(from: random.count - 1, to: 0, by: -1) { random.swapAt(i, nextIndex(i + 1)) }

        await Task.detached {
            var frame = 0
            for size in increasing + random {
                let output = render(node, frames: size) { sineWave(frequency: 220, amplitude: 0.7, frame: $0 + frame) }
                #expect(output.left.allSatisfy { $0.isFinite })
                #expect(output.right.allSatisfy { $0.isFinite })
                let expected = (0..<size).map { sineWave(frequency: 220, amplitude: 0.7, frame: $0 + frame) }
                for i in 0..<size { #expect(abs(output.left[i] - expected[i]) < 1e-5) }
                frame += size
            }
        }.value
        #expect(node.renderErrorCount == 0)
    }

    @Test("A mono-channel block is summed/duplicated across a stereo-negotiated plugin")
    func monoChannelAdaptation() async throws {
        let node = try await AUHostNode.load(ref: BuiltIn.delay, state: nil, sampleRate: sampleRate)
        node.params.set(try paramIndex(node, named: "Dry/Wet Mix"), 0) // pure dry: output should equal input
        let output = render(node, frames: 512, channels: 1) { sineWave(frequency: 300, amplitude: 0.3, frame: $0) }
        #expect(output.left == output.right)
        #expect(output.left.allSatisfy { $0.isFinite })
    }
}
