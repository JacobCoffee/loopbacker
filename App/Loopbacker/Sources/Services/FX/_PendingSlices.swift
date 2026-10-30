import AppKit
import Foundation

// MARK: - Integration scaffolding, NOT real implementations.
//
// Everything in this file is a minimal pass-through standing in for a type another slice is
// building in parallel (see the shared contract), so `FXChain`/`FXNodeFactory`/`FXEngine`
// compile and can be exercised end-to-end before those slices land. The integration owner
// deletes this entire file at merge time, once the real `GateNode`, `EQNode`, `CompressorNode`,
// `LevelerNode`, `DeEsserNode`, `ChorusNode`, `PitchShiftNode`, `ReverbNode`, `DelayNode`,
// `LimiterNode`, `VoiceActivityDetector`, `AUHostNode`/`JSFXNode`/`AirwindowsNode`,
// `AUCatalog`/`JSFXCatalog`/`AirwindowsCatalog`, and `PluginEditorWindowController` replace it.
// No TODOs are needed here: this file's job is to disappear.

// MARK: - Built-in DSP stages (DSP slice)

final class GateNode: FXNode, @unchecked Sendable {
    let kind: FXNodeKind = .gate
    let specs = FXBuiltinSpecs.gate
    let params: FXParamStore
    let meters = FXMeters()
    let latencySamples = 0
    init(sampleRate: Float) { params = FXParamStore(specs: specs) }
    func process(_ block: FXBlock) {}
    func reset() {}
}

final class EQNode: FXNode, @unchecked Sendable {
    let kind: FXNodeKind = .eq
    let specs = FXBuiltinSpecs.eq
    let params: FXParamStore
    let meters = FXMeters()
    let latencySamples = 0
    init(sampleRate: Float) { params = FXParamStore(specs: specs) }
    func process(_ block: FXBlock) {}
    func reset() {}
    /// Any thread (the real implementation publishes lock-free); max 16 bands.
    func setBands(_ bands: [EQBandConfig]) {}
}

final class CompressorNode: FXNode, @unchecked Sendable {
    let kind: FXNodeKind = .compressor
    let specs = FXBuiltinSpecs.compressor
    let params: FXParamStore
    let meters = FXMeters()
    let latencySamples = 0
    init(sampleRate: Float) { params = FXParamStore(specs: specs) }
    func process(_ block: FXBlock) {}
    func reset() {}
}

final class LevelerNode: FXNode, @unchecked Sendable {
    let kind: FXNodeKind = .leveler
    let specs = FXBuiltinSpecs.leveler
    let params: FXParamStore
    let meters = FXMeters()
    let latencySamples = 0
    init(sampleRate: Float) { params = FXParamStore(specs: specs) }
    func process(_ block: FXBlock) {}
    func reset() {}
}

final class DeEsserNode: FXNode, @unchecked Sendable {
    let kind: FXNodeKind = .deEsser
    let specs = FXBuiltinSpecs.deEsser
    let params: FXParamStore
    let meters = FXMeters()
    let latencySamples = 0
    init(sampleRate: Float) { params = FXParamStore(specs: specs) }
    func process(_ block: FXBlock) {}
    func reset() {}
}

final class ChorusNode: FXNode, @unchecked Sendable {
    let kind: FXNodeKind = .chorus
    let specs = FXBuiltinSpecs.chorus
    let params: FXParamStore
    let meters = FXMeters()
    let latencySamples = 0
    init(sampleRate: Float) { params = FXParamStore(specs: specs) }
    func process(_ block: FXBlock) {}
    func reset() {}
}

final class PitchShiftNode: FXNode, @unchecked Sendable {
    let kind: FXNodeKind = .pitchShift
    let specs = FXBuiltinSpecs.pitchShift
    let params: FXParamStore
    let meters = FXMeters()
    let latencySamples = 0
    init(sampleRate: Float) { params = FXParamStore(specs: specs) }
    func process(_ block: FXBlock) {}
    func reset() {}
}

final class ReverbNode: FXNode, @unchecked Sendable {
    let kind: FXNodeKind = .reverb
    let specs = FXBuiltinSpecs.reverb
    let params: FXParamStore
    let meters = FXMeters()
    let latencySamples = 0
    init(sampleRate: Float) { params = FXParamStore(specs: specs) }
    func process(_ block: FXBlock) {}
    func reset() {}
}

final class DelayNode: FXNode, @unchecked Sendable {
    let kind: FXNodeKind = .delay
    let specs = FXBuiltinSpecs.delay
    let params: FXParamStore
    let meters = FXMeters()
    let latencySamples = 0
    init(sampleRate: Float) { params = FXParamStore(specs: specs) }
    func process(_ block: FXBlock) {}
    func reset() {}
}

final class LimiterNode: FXNode, @unchecked Sendable {
    let kind: FXNodeKind = .limiter
    let specs = FXBuiltinSpecs.limiter
    let params: FXParamStore
    let meters = FXMeters()
    let latencySamples = 0
    init(sampleRate: Float) { params = FXParamStore(specs: specs) }
    func process(_ block: FXBlock) {}
    func reset() {}
}

/// Stands in for the RNNoise-based detector: always reports full confidence, so gate "Voice"
/// mode and app-audio ducking behave like "always speaking" until the real detector lands.
final class VoiceActivityDetector: @unchecked Sendable {
    init?() {}
    func process(_ mono: UnsafePointer<Float>, frames: Int) -> Float { 1 }
    func reset() {}
}
