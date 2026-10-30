import AppKit
import Foundation
import Synchronization

// MARK: - Parameters

enum FXUnit: String, Sendable {
    case dB, ms, hz, ratio, percent, semitones, lufs, seconds, none
}

enum FXScale: Sendable {
    case linear
    /// Logarithmic slider travel (frequencies, times). `min` must be > 0.
    case log
}

/// Describes one parameter of a stage. The position of a spec in `FXNode.specs` is the
/// parameter's index in `FXNode.params`.
struct FXParamSpec: Sendable, Identifiable, Equatable {
    /// Stable key used in `FXNodeConfig.params`. Never rename a shipped id.
    let id: String
    let name: String
    /// One short sentence shown under the name.
    let detail: String
    let unit: FXUnit
    let min: Float
    let max: Float
    let defaultValue: Float
    var scale: FXScale = .linear
    /// Discrete choice parameters: the value is the index into `choices`.
    var choices: [String]? = nil
    /// Hosted parameters: the plugin's own address (AU `AUParameterAddress`, JSFX slider
    /// index, Airwindows parameter index).
    var hostAddress: UInt64? = nil

    static func == (a: FXParamSpec, b: FXParamSpec) -> Bool { a.id == b.id }
}

/// Lock-free parameter values. Any thread writes; the IO thread reads. Writers bump
/// `generation`, so a stage can recompute derived values (coefficients) once per change at the
/// top of its next block instead of every sample.
final class FXParamStore: @unchecked Sendable {
    let count: Int
    private let values: UnsafeMutablePointer<Atomic<UInt32>>
    private let generationCounter = Atomic<UInt32>(0)

    init(specs: [FXParamSpec]) {
        count = specs.count
        values = .allocate(capacity: max(count, 1))
        for (i, spec) in specs.enumerated() {
            (values + i).initialize(to: Atomic(spec.defaultValue.bitPattern))
        }
    }

    deinit {
        values.deinitialize(count: count)
        values.deallocate()
    }

    /// Any thread.
    func set(_ index: Int, _ value: Float) {
        guard index >= 0, index < count else { return }
        values[index].store(value.bitPattern, ordering: .relaxed)
        generationCounter.add(1, ordering: .releasing)
    }

    /// Any thread (IO thread included).
    func get(_ index: Int) -> Float {
        Float(bitPattern: values[index].load(ordering: .relaxed))
    }

    /// Changes whenever any value is set. IO thread compares against its last seen value.
    var generation: UInt32 { generationCounter.load(ordering: .acquiring) }
}

// MARK: - Meters

/// Levels a stage publishes for the UI. The IO thread stores; the main thread polls.
final class FXMeters: @unchecked Sendable {
    private let inBits = Atomic<UInt32>(0)
    private let outBits = Atomic<UInt32>(0)
    private let grBits = Atomic<UInt32>(0)
    private let activityBits = Atomic<UInt32>(0)

    /// Linear peak of the block entering / leaving the stage (0...).
    var inputPeak: Float {
        get { Float(bitPattern: inBits.load(ordering: .relaxed)) }
        set { inBits.store(newValue.bitPattern, ordering: .relaxed) }
    }
    var outputPeak: Float {
        get { Float(bitPattern: outBits.load(ordering: .relaxed)) }
        set { outBits.store(newValue.bitPattern, ordering: .relaxed) }
    }
    /// Current gain reduction in dB, as a positive number (0 = none).
    var gainReductionDB: Float {
        get { Float(bitPattern: grBits.load(ordering: .relaxed)) }
        set { grBits.store(newValue.bitPattern, ordering: .relaxed) }
    }
    /// Stage-specific 0...1 state: gate openness, de-esser activity, leveler's measured
    /// short-term loudness mapped by the stage (documented on the stage).
    var activity: Float {
        get { Float(bitPattern: activityBits.load(ordering: .relaxed)) }
        set { activityBits.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

// MARK: - Processing

/// Signals shared by every stage of one chain for the current block.
struct FXSidechain {
    /// Probability (0...1) that the mic carries speech right now, from the chain's voice
    /// activity detector. 1 when no detector is running.
    var voiceProbability: Float
}

/// A block of planar audio, processed in place. `frames <= FXBlock.maxFrames`.
struct FXBlock {
    static let maxFrames = 4096

    let left: UnsafeMutablePointer<Float>
    /// Same pointer as `left` when `channels == 1`.
    let right: UnsafeMutablePointer<Float>
    let frames: Int
    /// 1 or 2.
    let channels: Int
    let sidechain: FXSidechain
}

/// One stage of the voice chain.
///
/// Real-time contract for `process` and `reset`: no allocation, locks, Objective-C messaging,
/// file or console I/O, or unbounded waits. Everything the IO thread touches is allocated in
/// `init`. Instances are created and destroyed off the IO thread.
protocol FXNode: AnyObject, Sendable {
    var kind: FXNodeKind { get }
    /// Fixed for the stage's lifetime.
    var specs: [FXParamSpec] { get }
    var params: FXParamStore { get }
    var meters: FXMeters { get }
    /// Samples the stage delays its output by. Fixed for the stage's lifetime.
    var latencySamples: Int { get }

    /// IO thread.
    func process(_ block: FXBlock)
    /// IO thread: clear all history (delay lines, envelopes) without allocating.
    func reset()
}

extension FXNode {
    func index(ofParam id: String) -> Int? { specs.firstIndex { $0.id == id } }

    /// Applies persisted values to `params`; ids not in `specs` are ignored.
    func apply(_ values: [String: Float]) {
        for (i, spec) in specs.enumerated() {
            if let v = values[spec.id] { params.set(i, min(max(v, spec.min), spec.max)) }
        }
    }

    /// Current values keyed by spec id, for persisting.
    func currentValues() -> [String: Float] {
        var out: [String: Float] = [:]
        for (i, spec) in specs.enumerated() { out[spec.id] = params.get(i) }
        return out
    }
}

/// A third-party effect (Audio Unit, JSFX, Airwindows).
protocol FXHostedNode: FXNode {
    var ref: FXPluginRef { get }
    /// Main thread: the effect's full state for `FXNodeConfig.pluginState`.
    @MainActor func captureState() -> Data?
    /// Main thread: an editor for the effect, or nil to use Loopbacker's generic parameter UI.
    @MainActor func makeEditor() async -> NSViewController?
}

/// Lists hosted effects of one format for the effect browser.
protocol FXPluginCatalog {
    static func scan() async -> [FXPluginInfo]
}

// MARK: - Helpers

/// One-pole parameter smoother: `value` approaches `target` with time constant `timeMs`.
/// Use it on every parameter that scales audio, so slider drags don't zipper.
struct FXSmoother {
    private(set) var value: Float
    var target: Float
    private let coeff: Float

    init(initial: Float, timeMs: Float = 20, sampleRate: Float) {
        value = initial
        target = initial
        coeff = expf(-1 / max(timeMs * sampleRate / 1000, 1))
    }

    @inline(__always) mutating func next() -> Float {
        value = target + coeff * (value - target)
        return value
    }

    mutating func snap() { value = target }

    var isSettled: Bool { abs(value - target) <= 1e-6 * max(abs(target), 1) }
}

@inline(__always) func fxDBToLinear(_ dB: Float) -> Float { powf(10, dB / 20) }
@inline(__always) func fxLinearToDB(_ x: Float) -> Float { 20 * log10f(max(x, 1e-10)) }

/// One-pole smoothing coefficient for a time constant: `y = c * y + (1 - c) * x`.
@inline(__always) func fxTimeCoeff(ms: Float, sampleRate: Float) -> Float {
    ms > 0 ? expf(-1 / (ms * sampleRate / 1000)) : 0
}
