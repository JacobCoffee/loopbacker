import Accelerate
import Foundation

// MARK: - Denormal safety

/// Flushes magnitudes below the denormal threshold to exact zero. Filter/envelope state left to
/// decay naturally on silent input would otherwise spend the rest of the call on denormals (a
/// 10-100x slowdown on most FPUs that lack flush-to-zero for `Double`).
@inline(__always) func fxFlush(_ x: Double) -> Double {
    abs(x) < 1e-300 ? 0 : x
}

@inline(__always) func fxFlush(_ x: Float) -> Float {
    abs(x) < 1e-30 ? 0 : x
}

// MARK: - Biquad (RBJ cookbook)

/// Normalized second-order section coefficients (`a0 == 1`), computed in `Double` so coefficient
/// math for low frequencies (e.g. an 80 Hz high-pass at 48 kHz) doesn't lose precision the way
/// `Float` does when `cos(omega)` sits close to 1.
struct FXBiquadCoeffs: Sendable {
    var b0: Double = 1, b1: Double = 0, b2: Double = 0, a1: Double = 0, a2: Double = 0

    static let identity = FXBiquadCoeffs()

    /// Robert Bristow-Johnson's "Audio EQ Cookbook" formulas.
    static func make(type: EQBandConfig.BandType, frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> FXBiquadCoeffs {
        let freq = min(max(frequency, 1), sampleRate * 0.49)
        let w0 = 2 * Double.pi * freq / sampleRate
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let qq = max(q, 0.05)
        let alpha = sinw0 / (2 * qq)
        let a = pow(10, gainDB / 40)
        var c = FXBiquadCoeffs()
        var a0 = 1.0
        switch type {
        case .highpass:
            c.b0 = (1 + cosw0) / 2
            c.b1 = -(1 + cosw0)
            c.b2 = (1 + cosw0) / 2
            a0 = 1 + alpha
            c.a1 = -2 * cosw0
            c.a2 = 1 - alpha
        case .lowpass:
            c.b0 = (1 - cosw0) / 2
            c.b1 = 1 - cosw0
            c.b2 = (1 - cosw0) / 2
            a0 = 1 + alpha
            c.a1 = -2 * cosw0
            c.a2 = 1 - alpha
        case .notch:
            c.b0 = 1
            c.b1 = -2 * cosw0
            c.b2 = 1
            a0 = 1 + alpha
            c.a1 = -2 * cosw0
            c.a2 = 1 - alpha
        case .peaking:
            c.b0 = 1 + alpha * a
            c.b1 = -2 * cosw0
            c.b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            c.a1 = -2 * cosw0
            c.a2 = 1 - alpha / a
        case .lowshelf:
            let beta = sqrt(a) / qq
            c.b0 = a * ((a + 1) - (a - 1) * cosw0 + beta * sinw0)
            c.b1 = 2 * a * ((a - 1) - (a + 1) * cosw0)
            c.b2 = a * ((a + 1) - (a - 1) * cosw0 - beta * sinw0)
            a0 = (a + 1) + (a - 1) * cosw0 + beta * sinw0
            c.a1 = -2 * ((a - 1) + (a + 1) * cosw0)
            c.a2 = (a + 1) + (a - 1) * cosw0 - beta * sinw0
        case .highshelf:
            let beta = sqrt(a) / qq
            c.b0 = a * ((a + 1) + (a - 1) * cosw0 + beta * sinw0)
            c.b1 = -2 * a * ((a - 1) + (a + 1) * cosw0)
            c.b2 = a * ((a + 1) + (a - 1) * cosw0 - beta * sinw0)
            a0 = (a + 1) - (a - 1) * cosw0 + beta * sinw0
            c.a1 = 2 * ((a - 1) - (a + 1) * cosw0)
            c.a2 = (a + 1) - (a - 1) * cosw0 - beta * sinw0
        }
        c.b0 /= a0; c.b1 /= a0; c.b2 /= a0; c.a1 /= a0; c.a2 /= a0
        return c
    }

    /// `k`th pole Q of an order-`order` (even) Butterworth filter, for cascading `order / 2`
    /// RBJ highpass/lowpass sections (each contributing 12 dB/octave) at the same corner
    /// frequency into a maximally-flat slope of `order * 6` dB/octave.
    static func butterworthQ(order: Int, section k: Int) -> Double {
        let theta = Double.pi * Double(2 * k + 1) / Double(2 * order)
        return 1 / (2 * cos(theta))
    }
}

/// Direct-form-II-transposed biquad state. `Double` accumulators stay accurate through many
/// cascaded sections; denormals are flushed every sample since voice stages run through long
/// silences.
struct FXBiquadState: Sendable {
    private var z1: Double = 0
    private var z2: Double = 0

    @inline(__always) mutating func process(_ x: Double, _ c: FXBiquadCoeffs) -> Double {
        let y = c.b0 * x + z1
        z1 = fxFlush(c.b1 * x - c.a1 * y + z2)
        z2 = fxFlush(c.b2 * x - c.a2 * y)
        return y
    }

    mutating func reset() { z1 = 0; z2 = 0 }
}

// MARK: - Envelope helpers

/// Peak of a stereo (or mono-duplicated) block, for `FXMeters.inputPeak`/`outputPeak`.
@inline(__always) func fxBlockPeak(_ block: FXBlock) -> Float {
    var peak: Float = 0
    vDSP_maxmgv(block.left, 1, &peak, vDSP_Length(block.frames))
    if block.channels == 2 {
        var rightPeak: Float = 0
        vDSP_maxmgv(block.right, 1, &rightPeak, vDSP_Length(block.frames))
        peak = max(peak, rightPeak)
    }
    return peak
}

/// Branching one-pole envelope follower in the dB domain: different time constants rising
/// (attack) vs. falling (release), the standard approach for dynamics processors so a stage
/// reacts quickly to new peaks but recovers gently.
struct FXEnvelopeDB {
    private(set) var value: Float
    private var attackCoeff: Float
    private var releaseCoeff: Float

    init(initial: Float = -120) {
        value = initial
        attackCoeff = 0
        releaseCoeff = 0
    }

    mutating func setTimes(attackMs: Float, releaseMs: Float, sampleRate: Float) {
        attackCoeff = fxTimeCoeff(ms: attackMs, sampleRate: sampleRate)
        releaseCoeff = fxTimeCoeff(ms: releaseMs, sampleRate: sampleRate)
    }

    @inline(__always) mutating func next(_ inputDB: Float) -> Float {
        let c = inputDB > value ? attackCoeff : releaseCoeff
        value = inputDB + c * (value - inputDB)
        return value
    }

    mutating func reset(to level: Float = -120) { value = level }
}

/// Soft clip (tanh-shaped via a rational approximation) used in feedback paths (chorus, delay)
/// so runaway feedback saturates instead of clipping harshly or blowing up.
@inline(__always) func fxSoftClip(_ x: Float) -> Float {
    let c = max(-3, min(3, x))
    return c * (27 + c * c) / (27 + 9 * c * c)
}

// MARK: - LFO rotation renormalization

/// Renormalizes a 2D unit-vector LFO rotation recurrence (`c' = c*rc - s*rs; s' = c*rs + s*rc`,
/// used by `ChorusNode` and `ReverbNode` for per-sample modulation without calling `sinf`/
/// `cosf` every sample) back to unit magnitude. That recurrence is an exact rotation only in
/// infinite precision; in `Float` it drifts the vector's magnitude away from 1 over a
/// long-running session, growing the modulation depth unboundedly until delay reads wrap into
/// unrelated audio. Cheap to call every sample: the magnitude check is the only extra work
/// unless drift has actually accumulated, when one `rsqrt` corrects it.
@inline(__always) func fxRenormalizeLFO(_ cosValue: inout Float, _ sinValue: inout Float) {
    let magSq = cosValue * cosValue + sinValue * sinValue
    guard abs(magSq - 1) > 1e-6 else { return }
    let invMag = 1 / sqrtf(magSq)
    cosValue *= invMag
    sinValue *= invMag
}

// MARK: - BS.1770 K-weighting

/// ITU-R BS.1770 K-weighting: a head-related high-shelf stage (Annex 1 Table 1) cascaded with
/// an RLB (revised low-frequency B) high-pass stage (Annex 1 Table 2). Annex 1 tabulates
/// coefficients only at 48 kHz, and those coefficients are *not* reproducible by passing the
/// quoted frequency/Q into `FXBiquadCoeffs.make`: the shelf uses a different analog prototype
/// than the RBJ cookbook shelf, and the high-pass's published numerator is the un-normalized
/// `[1, -2, 1]`, not RBJ's `(1+cos(w0))`-scaled one. This derives the same two stages from
/// their analog prototypes (corner frequency + Q) via the bilinear transform with frequency
/// pre-warping, the standard approach (used by libebur128) for sample rates other than 48 kHz;
/// at `sampleRate == 48_000` it reproduces the Annex 1 Table 1/Table 2 values to within
/// floating-point epsilon (`FXDSPTests`). `LevelerNode`, `AutoSetup`, and the test support's
/// `measuredLUFS` all build their filters from this one implementation, so "LUFS" means the
/// same measurement everywhere in the app and in its tests.
enum FXKWeighting {
    private static let shelfGainDB = 3.999843853973347
    private static let shelfFrequency = 1681.9744509555319
    private static let shelfQ = 0.7071752369554196
    /// Exact exponent relating the shelf's bandwidth gain to its DC gain (libebur128); not
    /// `sqrt(vh)` -- the small difference is required to reproduce the published coefficients.
    private static let shelfVbExponent = 0.4996667741545416

    private static let highpassFrequency = 38.13547087602444
    private static let highpassQ = 0.5003270373238773

    /// `(shelf, highpass)` biquad coefficients for `sampleRate`, in `FXBiquadState`'s
    /// convention (`y = b0 x[n] + b1 x[n-1] + b2 x[n-2] - a1 y[n-1] - a2 y[n-2]`, `a0` already
    /// divided out).
    static func coefficients(sampleRate: Double) -> (shelf: FXBiquadCoeffs, highpass: FXBiquadCoeffs) {
        let vh = pow(10, shelfGainDB / 20)
        let vb = pow(vh, shelfVbExponent)
        let kShelf = tan(Double.pi * shelfFrequency / sampleRate)
        let a0Shelf = 1 + kShelf / shelfQ + kShelf * kShelf
        var shelf = FXBiquadCoeffs()
        shelf.b0 = (vh + vb * (kShelf / shelfQ) + kShelf * kShelf) / a0Shelf
        shelf.b1 = (2 * (kShelf * kShelf - vh)) / a0Shelf
        shelf.b2 = (vh - vb * (kShelf / shelfQ) + kShelf * kShelf) / a0Shelf
        shelf.a1 = (2 * (kShelf * kShelf - 1)) / a0Shelf
        shelf.a2 = (1 - kShelf / shelfQ + kShelf * kShelf) / a0Shelf

        let kHP = tan(Double.pi * highpassFrequency / sampleRate)
        let a0HP = 1 + kHP / highpassQ + kHP * kHP
        var highpass = FXBiquadCoeffs()
        highpass.b0 = 1
        highpass.b1 = -2
        highpass.b2 = 1
        highpass.a1 = (2 * (kHP * kHP - 1)) / a0HP
        highpass.a2 = (1 - kHP / highpassQ + kHP * kHP) / a0HP
        return (shelf, highpass)
    }
}
