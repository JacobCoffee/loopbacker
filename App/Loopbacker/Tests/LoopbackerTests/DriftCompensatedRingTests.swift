import Testing
@testable import Loopbacker

/// Regression coverage for the [ReviewRT] "give each echo canceller its own reference reader"
/// finding: before `DriftCompensatedRing.Reader` existed, two `EchoCanceller`s on different
/// capture devices both reading one `SystemAudioTap.ring` shared its single `readPos`/
/// `readFrac`/`fillEstimate`/`priming` cursor, racing it and stealing each other's frames
/// instead of each independently tracking the same far-end timeline. These tests exercise
/// `DriftCompensatedRing.makeReader()` directly (no `EchoCanceller`/CoreAudio needed): the same
/// underlying mechanism two cancellers would use.
@Suite("DriftCompensatedRing multi-reader")
struct DriftCompensatedRingReaderTests {
    private func makeRampRing(totalFrames: Int, targetFill: UInt32 = 480) -> DriftCompensatedRing {
        var capacity: UInt32 = 1 << 12
        while capacity < UInt32(totalFrames) { capacity <<= 1 }
        let ring = DriftCompensatedRing(capacityFrames: capacity, channels: 1, targetFill: targetFill, sampleRate: 48_000)
        var ramp = [Float](repeating: 0, count: totalFrames)
        for i in 0..<totalFrames { ramp[i] = Float(i) }
        ramp.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: UInt32(totalFrames)) }
        return ring
    }

    @Test("Two independent readers on the same ring each see the same far-end timeline")
    func independentReadersSeeTheSameTimeline() {
        let totalFrames = 4_000
        let ring = makeRampRing(totalFrames: totalFrames)
        let readerA = ring.makeReader()
        let readerB = ring.makeReader()

        var outA = [Float](repeating: 0, count: 2_000)
        var outB = [Float](repeating: 0, count: 2_000)
        outA.withUnsafeMutableBufferPointer { readerA.read(into: $0.baseAddress!, frames: 2_000) }
        outB.withUnsafeMutableBufferPointer { readerB.read(into: $0.baseAddress!, frames: 2_000) }

        // Both readers started fresh against the same written data with the same target fill,
        // so their interpolated output must match closely -- if they were secretly sharing one
        // cursor, the second call would start wherever the first call's cursor had advanced to
        // instead of from the same starting point.
        var maxDiff: Float = 0
        for i in 0..<outA.count { maxDiff = max(maxDiff, abs(outA[i] - outB[i])) }
        #expect(maxDiff < 0.01, "independent readers diverged by \(maxDiff), suggesting a shared cursor")
    }

    @Test("Reading further from one reader never perturbs another reader's independent cursor")
    func oneReadersProgressDoesNotAffectAnother() {
        let totalFrames = 4_000
        let ring = makeRampRing(totalFrames: totalFrames)
        let readerA = ring.makeReader()
        let readerB = ring.makeReader()
        // Never touched by A's extra reads below; same warm-up as B, so B must match this
        // reader's next read exactly if (and only if) A's progress never leaked into B.
        let readerControl = ring.makeReader()

        func warm(_ reader: DriftCompensatedRing.Reader) {
            var buffer = [Float](repeating: 0, count: 500)
            buffer.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: 500) }
        }
        warm(readerA)
        warm(readerB)
        warm(readerControl)

        // Only A advances further.
        var farA = [Float](repeating: 0, count: 1_500)
        farA.withUnsafeMutableBufferPointer { readerA.read(into: $0.baseAddress!, frames: 1_500) }

        // B and the untouched control reader take the identical next step. If B secretly
        // shared A's cursor (the pre-`Reader` bug), it would diverge from the control here.
        var nextB = [Float](repeating: 0, count: 100)
        var nextControl = [Float](repeating: 0, count: 100)
        nextB.withUnsafeMutableBufferPointer { readerB.read(into: $0.baseAddress!, frames: 100) }
        nextControl.withUnsafeMutableBufferPointer { readerControl.read(into: $0.baseAddress!, frames: 100) }

        var maxDiff: Float = 0
        for i in 0..<100 { maxDiff = max(maxDiff, abs(nextB[i] - nextControl[i])) }
        #expect(maxDiff < 0.01, "reader B diverged from an untouched control reader after A advanced further (diff \(maxDiff)), suggesting a shared cursor")
    }

    @Test("The single-reader convenience read(into:frames:) still works for one consumer")
    func singleReaderConvenienceStillWorks() {
        let totalFrames = 2_000
        let ring = makeRampRing(totalFrames: totalFrames)
        var out = [Float](repeating: 0, count: 1_000)
        out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: 1_000) }
        #expect(out.allSatisfy { $0.isFinite })
        // Should be reading real ramp data (not silence) once past the startup cushion.
        #expect(out.last! > 0)
    }
}
