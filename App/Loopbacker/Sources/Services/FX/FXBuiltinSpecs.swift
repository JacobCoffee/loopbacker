import Foundation

/// Parameters of every built-in stage. Ids are persisted: never rename a shipped one.
/// Percent parameters run 0...100. Choice parameters store the choice index.
enum FXBuiltinSpecs {
    static func specs(for kind: FXNodeKind) -> [FXParamSpec] {
        switch kind {
        case .gate: gate
        case .eq: eq
        case .compressor: compressor
        case .leveler: leveler
        case .deEsser: deEsser
        case .chorus: chorus
        case .pitchShift: pitchShift
        case .reverb: reverb
        case .delay: delay
        case .limiter: limiter
        case .audioUnit, .jsfx, .airwindows: []
        }
    }

    static func defaultValue(_ kind: FXNodeKind, _ id: String) -> Float? {
        specs(for: kind).first { $0.id == id }?.defaultValue
    }

    static let gate: [FXParamSpec] = [
        FXParamSpec(id: "mode", name: "Trigger", detail: "Open on speech (ignores clicks and taps) or on level alone",
                    unit: .none, min: 0, max: 1, defaultValue: 1, choices: ["Level", "Voice"]),
        FXParamSpec(id: "threshold", name: "Threshold", detail: "Level the gate opens at",
                    unit: .dB, min: -80, max: 0, defaultValue: -45),
        FXParamSpec(id: "hysteresis", name: "Hysteresis", detail: "How far below the threshold it closes, so word endings don't chatter",
                    unit: .dB, min: 0, max: 12, defaultValue: 4),
        FXParamSpec(id: "voiceSensitivity", name: "Voice Sensitivity", detail: "How readily speech opens the gate in Voice mode",
                    unit: .percent, min: 0, max: 100, defaultValue: 50),
        FXParamSpec(id: "attack", name: "Attack", detail: "How fast the gate opens",
                    unit: .ms, min: 0.1, max: 50, defaultValue: 1, scale: .log),
        FXParamSpec(id: "hold", name: "Hold", detail: "How long it stays open after the signal drops",
                    unit: .ms, min: 0, max: 500, defaultValue: 120),
        FXParamSpec(id: "release", name: "Release", detail: "How fast the gate closes",
                    unit: .ms, min: 10, max: 1000, defaultValue: 200, scale: .log),
        FXParamSpec(id: "range", name: "Range", detail: "Attenuation while closed",
                    unit: .dB, min: -80, max: 0, defaultValue: -20),
        FXParamSpec(id: "keyHighPass", name: "Key High-Pass", detail: "Ignores rumble and breath when deciding to open",
                    unit: .hz, min: 20, max: 500, defaultValue: 80, scale: .log),
    ]

    /// Bands live in `FXNodeConfig.eqBands`.
    static let eq: [FXParamSpec] = [
        FXParamSpec(id: "outputGain", name: "Output", detail: "Gain after the EQ",
                    unit: .dB, min: -12, max: 12, defaultValue: 0),
    ]

    static let compressor: [FXParamSpec] = [
        FXParamSpec(id: "threshold", name: "Threshold", detail: "Level above which compression starts",
                    unit: .dB, min: -60, max: 0, defaultValue: -20),
        FXParamSpec(id: "ratio", name: "Ratio", detail: "How strongly levels above the threshold are reduced",
                    unit: .ratio, min: 1, max: 20, defaultValue: 3, scale: .log),
        FXParamSpec(id: "knee", name: "Knee", detail: "Width of the gradual transition around the threshold",
                    unit: .dB, min: 0, max: 24, defaultValue: 6),
        FXParamSpec(id: "attack", name: "Attack", detail: "How fast it reacts to peaks",
                    unit: .ms, min: 0.1, max: 200, defaultValue: 10, scale: .log),
        FXParamSpec(id: "release", name: "Release", detail: "How fast it recovers",
                    unit: .ms, min: 10, max: 2000, defaultValue: 150, scale: .log),
        FXParamSpec(id: "detector", name: "Detector", detail: "React to peaks or to average loudness",
                    unit: .none, min: 0, max: 1, defaultValue: 1, choices: ["Peak", "RMS"]),
        FXParamSpec(id: "makeup", name: "Makeup", detail: "Gain added after compression",
                    unit: .dB, min: 0, max: 24, defaultValue: 0),
        FXParamSpec(id: "mix", name: "Mix", detail: "Blend with the uncompressed signal (parallel compression)",
                    unit: .percent, min: 0, max: 100, defaultValue: 100),
    ]

    static let leveler: [FXParamSpec] = [
        FXParamSpec(id: "target", name: "Target", detail: "Loudness to hold your voice at while speaking",
                    unit: .lufs, min: -30, max: -10, defaultValue: -18),
        FXParamSpec(id: "maxBoost", name: "Max Boost", detail: "Most it will raise a quiet voice",
                    unit: .dB, min: 0, max: 24, defaultValue: 12),
        FXParamSpec(id: "maxCut", name: "Max Cut", detail: "Most it will lower a loud voice",
                    unit: .dB, min: 0, max: 24, defaultValue: 12),
        FXParamSpec(id: "speed", name: "Response", detail: "How quickly it follows changes in your level",
                    unit: .ms, min: 200, max: 10000, defaultValue: 1500, scale: .log),
    ]

    static let deEsser: [FXParamSpec] = [
        FXParamSpec(id: "frequency", name: "Frequency", detail: "Where sibilance is detected",
                    unit: .hz, min: 3000, max: 12000, defaultValue: 6500, scale: .log),
        FXParamSpec(id: "threshold", name: "Threshold", detail: "Sibilance level that triggers reduction",
                    unit: .dB, min: -60, max: 0, defaultValue: -30),
        FXParamSpec(id: "range", name: "Max Reduction", detail: "Most it will turn down an S",
                    unit: .dB, min: 0, max: 24, defaultValue: 8),
        FXParamSpec(id: "mode", name: "Mode", detail: "Reduce only the harsh band, or the whole signal",
                    unit: .none, min: 0, max: 1, defaultValue: 0, choices: ["Split-band", "Wideband"]),
    ]

    static let chorus: [FXParamSpec] = [
        FXParamSpec(id: "rate", name: "Rate", detail: "Modulation speed",
                    unit: .hz, min: 0.05, max: 5, defaultValue: 0.8, scale: .log),
        FXParamSpec(id: "depth", name: "Depth", detail: "Modulation amount",
                    unit: .ms, min: 0, max: 10, defaultValue: 1.5),
        FXParamSpec(id: "mix", name: "Mix", detail: "Dry/wet balance",
                    unit: .percent, min: 0, max: 100, defaultValue: 30),
    ]

    static let pitchShift: [FXParamSpec] = [
        FXParamSpec(id: "semitones", name: "Pitch", detail: "Shift in semitones",
                    unit: .semitones, min: -12, max: 12, defaultValue: 0),
        FXParamSpec(id: "formant", name: "Formant", detail: "Shift the vocal character independently of pitch",
                    unit: .semitones, min: -12, max: 12, defaultValue: 0),
        FXParamSpec(id: "preserveFormants", name: "Preserve Formants", detail: "Keep the voice natural when shifting pitch",
                    unit: .none, min: 0, max: 1, defaultValue: 1, choices: ["Off", "On"]),
        FXParamSpec(id: "mix", name: "Mix", detail: "Dry/wet balance",
                    unit: .percent, min: 0, max: 100, defaultValue: 100),
    ]

    static let reverb: [FXParamSpec] = [
        FXParamSpec(id: "size", name: "Room Size", detail: "Size of the simulated space",
                    unit: .percent, min: 0, max: 100, defaultValue: 50),
        FXParamSpec(id: "damping", name: "Damping", detail: "High-frequency absorption",
                    unit: .percent, min: 0, max: 100, defaultValue: 50),
        FXParamSpec(id: "preDelay", name: "Pre-Delay", detail: "Gap before the reverb starts",
                    unit: .ms, min: 0, max: 200, defaultValue: 10),
        FXParamSpec(id: "mix", name: "Mix", detail: "Dry/wet balance",
                    unit: .percent, min: 0, max: 100, defaultValue: 15),
    ]

    static let delay: [FXParamSpec] = [
        FXParamSpec(id: "time", name: "Time", detail: "Delay time",
                    unit: .ms, min: 10, max: 1000, defaultValue: 250, scale: .log),
        FXParamSpec(id: "feedback", name: "Feedback", detail: "How much of the echo repeats",
                    unit: .percent, min: 0, max: 90, defaultValue: 30),
        FXParamSpec(id: "highCut", name: "High Cut", detail: "Darkens each repeat",
                    unit: .hz, min: 1000, max: 20000, defaultValue: 8000, scale: .log),
        FXParamSpec(id: "mix", name: "Mix", detail: "Dry/wet balance",
                    unit: .percent, min: 0, max: 100, defaultValue: 25),
    ]

    static let limiter: [FXParamSpec] = [
        FXParamSpec(id: "inputGain", name: "Input Gain", detail: "Drive into the limiter",
                    unit: .dB, min: 0, max: 24, defaultValue: 0),
        FXParamSpec(id: "ceiling", name: "Ceiling", detail: "Maximum true-peak output level",
                    unit: .dB, min: -12, max: 0, defaultValue: -1),
        FXParamSpec(id: "release", name: "Release", detail: "How fast it recovers after a peak",
                    unit: .ms, min: 1, max: 1000, defaultValue: 60, scale: .log),
    ]
}
