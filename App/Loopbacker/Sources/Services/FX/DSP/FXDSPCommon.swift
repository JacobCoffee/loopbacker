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
