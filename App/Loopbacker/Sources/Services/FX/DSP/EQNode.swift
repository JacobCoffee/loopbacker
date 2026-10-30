import Accelerate
import Foundation
import Synchronization

/// One cascaded biquad section plus whether it's in use. Plain data so it can live in a raw
/// buffer and be copied/interpolated without Array CoW.
private struct FXEQSection: Sendable {
    var coeffs: FXBiquadCoeffs = .identity
    var enabled = false

    @inline(__always) static func lerp(_ a: FXEQSection, _ b: FXEQSection, _ t: Double) -> FXEQSection {
        var r = FXEQSection()
        r.enabled = a.enabled || b.enabled
        r.coeffs.b0 = a.coeffs.b0 + (b.coeffs.b0 - a.coeffs.b0) * t
        r.coeffs.b1 = a.coeffs.b1 + (b.coeffs.b1 - a.coeffs.b1) * t
        r.coeffs.b2 = a.coeffs.b2 + (b.coeffs.b2 - a.coeffs.b2) * t
        r.coeffs.a1 = a.coeffs.a1 + (b.coeffs.a1 - a.coeffs.a1) * t
        r.coeffs.a2 = a.coeffs.a2 + (b.coeffs.a2 - a.coeffs.a2) * t
        return r
    }
}

/// Parametric EQ: up to 16 bands (highpass, lowshelf, peaking, highshelf, lowpass, notch),
/// high/low-pass slopes of 12/24/48 dB/octave built from 1/2/4 cascaded RBJ biquads at
/// Butterworth Q's (maximally flat combined response), everything else a single RBJ section at
/// the band's own Q. State is `Double` (see `FXBiquadState`) because cascaded low-frequency
/// sections are numerically sensitive in `Float`.
///
/// `setBands` is called from the UI while the IO thread may be mid-block, so coefficients are
/// double-buffered: the writer (guarded by a `Mutex` so two concurrent editors don't tear a
/// buffer) fully builds the inactive buffer, then publishes it with one atomic store; the IO
/// thread only ever atomic-loads which buffer is current — never blocks, never sees a partial
/// write. On a publish, the IO thread doesn't jump-cut coefficients (an audible click on
/// resonant bands): it linearly interpolates each coefficient from the last live value to the
/// new one over ~5 ms, then snaps exactly to avoid drift.
final class EQNode: FXNode, @unchecked Sendable {
    private static let maxBands = 16
    private static let maxSectionsPerBand = 4
    private static let maxSections = maxBands * maxSectionsPerBand

    let kind: FXNodeKind = .eq
    let specs = FXBuiltinSpecs.eq
    let params: FXParamStore
    let meters = FXMeters()
    let latencySamples = 0

    private let sampleRate: Double
    private var lastGeneration: UInt32 = .max
    private var outputGain: FXSmoother

    // MARK: Published coefficients (writer: any thread; reader: IO thread)
    private let publishBuffers: [UnsafeMutablePointer<FXEQSection>]
    private let publishedIndex = Atomic<Int>(0)
    private let writeLock = Mutex<Void>(())

    // MARK: IO-thread-only state
    private let liveCoeffs: UnsafeMutablePointer<FXEQSection>
    private let fromCoeffs: UnsafeMutablePointer<FXEQSection>
    private var targetBufferIndex = 0
    private var lastAppliedIndex = 0
    private let rampTotal: Int
    private var rampRemaining = 0
    private let sectionStates: UnsafeMutablePointer<FXBiquadState> // [channel][section], channel-major

    init(sampleRate: Float) {
        self.sampleRate = Double(sampleRate)
        params = FXParamStore(specs: FXBuiltinSpecs.eq)
        outputGain = FXSmoother(initial: 1, timeMs: 20, sampleRate: sampleRate)
        rampTotal = max(1, Int(0.005 * sampleRate))

        publishBuffers = (0..<2).map { _ in
            let p = UnsafeMutablePointer<FXEQSection>.allocate(capacity: Self.maxSections)
            p.initialize(repeating: FXEQSection(), count: Self.maxSections)
            return p
        }
        liveCoeffs = .allocate(capacity: Self.maxSections)
        liveCoeffs.initialize(repeating: FXEQSection(), count: Self.maxSections)
        fromCoeffs = .allocate(capacity: Self.maxSections)
        fromCoeffs.initialize(repeating: FXEQSection(), count: Self.maxSections)
        sectionStates = .allocate(capacity: Self.maxSections * 2)
        sectionStates.initialize(repeating: FXBiquadState(), count: Self.maxSections * 2)
    }

    deinit {
        for b in publishBuffers { b.deinitialize(count: Self.maxSections); b.deallocate() }
        liveCoeffs.deinitialize(count: Self.maxSections); liveCoeffs.deallocate()
        fromCoeffs.deinitialize(count: Self.maxSections); fromCoeffs.deallocate()
        sectionStates.deinitialize(count: Self.maxSections * 2); sectionStates.deallocate()
    }

    /// Any thread. Builds the full section list for `bands` (≤16, extra ignored) into the
    /// currently-unpublished buffer, then publishes it. Disabled bands contribute no sections.
    func setBands(_ bands: [EQBandConfig]) {
        writeLock.withLock { _ in
            let target = 1 - publishedIndex.load(ordering: .relaxed)
            let buf = publishBuffers[target]
            var idx = 0
            for band in bands.prefix(Self.maxBands) where band.enabled {
                for c in Self.sections(for: band, sampleRate: sampleRate) {
                    guard idx < Self.maxSections else { break }
                    buf[idx] = FXEQSection(coeffs: c, enabled: true)
                    idx += 1
                }
            }
            for j in idx..<Self.maxSections { buf[j] = FXEQSection() }
            publishedIndex.store(target, ordering: .releasing)
        }
    }

    private static func sections(for band: EQBandConfig, sampleRate: Double) -> [FXBiquadCoeffs] {
        switch band.type {
        case .highpass, .lowpass:
            let order = max(1, min(4, band.slopeDBPerOctave / 12))
            return (0..<order).map { k in
                let q = FXBiquadCoeffs.butterworthQ(order: order * 2, section: k)
                return FXBiquadCoeffs.make(type: band.type, frequency: Double(band.frequencyHz), q: q, gainDB: 0, sampleRate: sampleRate)
            }
        default:
            return [FXBiquadCoeffs.make(type: band.type, frequency: Double(band.frequencyHz), q: Double(band.q), gainDB: Double(band.gainDB), sampleRate: sampleRate)]
        }
    }

    func reset() {
        for i in 0..<(Self.maxSections * 2) { sectionStates[i].reset() }
        rampRemaining = 0
        outputGain.snap()
    }

    func process(_ block: FXBlock) {
        let gen = params.generation
        if gen != lastGeneration {
            lastGeneration = gen
            outputGain.target = fxDBToLinear(params.get(0))
        }
        meters.inputPeak = fxBlockPeak(block)

        let pubIdx = publishedIndex.load(ordering: .acquiring)
        if pubIdx != lastAppliedIndex {
            fromCoeffs.update(from: liveCoeffs, count: Self.maxSections)
            targetBufferIndex = pubIdx
            lastAppliedIndex = pubIdx
            rampRemaining = rampTotal
        }

        let channels = block.channels
        for i in 0..<block.frames {
            if rampRemaining > 0 {
                let t = Double(rampTotal - rampRemaining + 1) / Double(rampTotal)
                let target = publishBuffers[targetBufferIndex]
                for s in 0..<Self.maxSections {
                    liveCoeffs[s] = FXEQSection.lerp(fromCoeffs[s], target[s], t)
                }
                rampRemaining -= 1
                if rampRemaining == 0 { liveCoeffs.update(from: target, count: Self.maxSections) }
            }

            let g = outputGain.next()
            for ch in 0..<channels {
                var x = Double(ch == 0 ? block.left[i] : block.right[i])
                let base = ch * Self.maxSections
                for s in 0..<Self.maxSections where liveCoeffs[s].enabled {
                    x = sectionStates[base + s].process(x, liveCoeffs[s].coeffs)
                }
                let y = Float(x) * g
                if ch == 0 { block.left[i] = y } else { block.right[i] = y }
            }
            if channels == 1 { block.right[i] = block.left[i] }
        }
        meters.outputPeak = fxBlockPeak(block)
    }
}
