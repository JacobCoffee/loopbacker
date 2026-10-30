import Testing
@testable import Loopbacker

/// `ProcessingGroupKey` decides which voice routes may share one noise suppressor, echo
/// canceller, or FX chain instance (`AudioRouter.sameProcessingGroup`/`attachFXChain`/
/// `applyNoiseSuppression`/`applyEchoCancellation`). `AudioRouter.RouteContext` is
/// `fileprivate` to `AudioRouter.swift` (and depends on real CoreAudio devices to construct),
/// so this exercises the key's actual signature math directly against plain mix-matrix arrays
/// -- the same production function `RouteContext.voicePairMixSignature` calls.
@Suite("ProcessingGroupKey")
struct ProcessingGroupKeyTests {
    /// A `dst * inputChannels + src` row-major mix matrix, like `RouteContext.mixMatrix`, with
    /// 1.0 at each given (srcCh, dstCh) 0-indexed pair and 0 elsewhere.
    private func matrix(inputChannels: Int, outputChannels: Int, routes: [(src: Int, dst: Int)]) -> [Float] {
        var m = [Float](repeating: 0, count: inputChannels * outputChannels)
        for r in routes { m[r.dst * inputChannels + r.src] = 1 }
        return m
    }

    private func signature(_ m: [Float], inputChannels: Int, outputChannels: Int) -> [UInt32] {
        m.withUnsafeBufferPointer {
            ProcessingGroupKey.voicePairSignature(matrix: $0.baseAddress!, inputChannels: inputChannels,
                                                  outputChannels: outputChannels)
        }
    }

    @Test("Identical device, rate, and mix share one processing group")
    func identicalRoutesShareGroup() {
        let m = matrix(inputChannels: 4, outputChannels: 4, routes: [(0, 0), (1, 1)])
        let sig = signature(m, inputChannels: 4, outputChannels: 4)
        let a = ProcessingGroupKey(captureDeviceUID: "mic-1", sampleRate: 48_000, voicePairSignature: sig)
        let b = ProcessingGroupKey(captureDeviceUID: "mic-1", sampleRate: 48_000, voicePairSignature: sig)
        #expect(a == b)
    }

    @Test("Different per-route mixes on the same device get separate processing groups")
    func differentMixesAreSeparateGroups() {
        // Virtual Mic: input 1 -> channels 1-2.
        let micMix = matrix(inputChannels: 4, outputChannels: 4, routes: [(0, 0), (0, 1)])
        // Stream Mix: input 2 -> channels 1-2 (a different voice pair entirely).
        let streamMix = matrix(inputChannels: 4, outputChannels: 4, routes: [(1, 0), (1, 1)])
        let micSig = signature(micMix, inputChannels: 4, outputChannels: 4)
        let streamSig = signature(streamMix, inputChannels: 4, outputChannels: 4)
        let a = ProcessingGroupKey(captureDeviceUID: "mic-1", sampleRate: 48_000, voicePairSignature: micSig)
        let b = ProcessingGroupKey(captureDeviceUID: "mic-1", sampleRate: 48_000, voicePairSignature: streamSig)
        #expect(a != b, "routes feeding different source channels into channels 1-2 must not share NS/AEC/FX")
    }

    @Test("A mix difference only in channels past 1-2 does not affect the group")
    func differencesBeyondVoicePairDontMatter() {
        // Both routes agree on channels 1-2 (the only channels NS/AEC/FX read/write); they
        // differ only in channel 3-4 routing, which is irrelevant to sharing those stages.
        let a1 = matrix(inputChannels: 4, outputChannels: 4, routes: [(0, 0), (1, 1), (2, 2)])
        let a2 = matrix(inputChannels: 4, outputChannels: 4, routes: [(0, 0), (1, 1), (3, 2)])
        let sigA1 = signature(a1, inputChannels: 4, outputChannels: 4)
        let sigA2 = signature(a2, inputChannels: 4, outputChannels: 4)
        #expect(sigA1 == sigA2, "channels 3-4 differ, but voicePairSignature only covers 1-2")
    }

    @Test("Different sample rates never share a processing group, even with an identical mix")
    func differentSampleRatesAreSeparateGroups() {
        let m = matrix(inputChannels: 2, outputChannels: 2, routes: [(0, 0), (1, 1)])
        let sig = signature(m, inputChannels: 2, outputChannels: 2)
        let a = ProcessingGroupKey(captureDeviceUID: "mic-1", sampleRate: 44_100, voicePairSignature: sig)
        let b = ProcessingGroupKey(captureDeviceUID: "mic-1", sampleRate: 48_000, voicePairSignature: sig)
        #expect(a != b)
    }

    @Test("Different capture devices never share a processing group, even with an identical mix and rate")
    func differentDevicesAreSeparateGroups() {
        let m = matrix(inputChannels: 2, outputChannels: 2, routes: [(0, 0), (1, 1)])
        let sig = signature(m, inputChannels: 2, outputChannels: 2)
        let a = ProcessingGroupKey(captureDeviceUID: "mic-1", sampleRate: 48_000, voicePairSignature: sig)
        let b = ProcessingGroupKey(captureDeviceUID: "mic-2", sampleRate: 48_000, voicePairSignature: sig)
        #expect(a != b)
    }

    @Test("A mono mic fanned to both output channels produces an identical signature across equivalent routes")
    func monoFanOutIsConsistent() {
        // A single mono source channel feeding both channels 1 and 2 (identity-style fan-out),
        // the common case for an ordinary mono mic -- two routes built the same way must still
        // compare equal.
        let m1 = matrix(inputChannels: 1, outputChannels: 2, routes: [(0, 0), (0, 1)])
        let m2 = matrix(inputChannels: 1, outputChannels: 2, routes: [(0, 0), (0, 1)])
        #expect(signature(m1, inputChannels: 1, outputChannels: 2) == signature(m2, inputChannels: 1, outputChannels: 2))
    }
}
