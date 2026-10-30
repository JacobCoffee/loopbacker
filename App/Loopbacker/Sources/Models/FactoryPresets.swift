import Foundation

/// Grouping shown in the preset picker.
enum FactoryPresetCategory: String, CaseIterable, Sendable {
    case business, gaming, streaming, creative
}

/// A shipped, curated voice-chain configuration plus the noise suppression / echo cancellation
/// it was designed around. Built entirely from the built-in stages (never a hosted plugin), so
/// every machine running Loopbacker can apply one without a plugin scan.
struct FactoryPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let category: FactoryPresetCategory
    let summary: String
    let symbol: String
    let preset: EffectsPreset
    /// Noise suppression this preset is designed around (engine/reduction), nil = leave as is.
    let noiseSuppression: NoiseSuppressionSettings?
    /// Echo cancellation recommendation for this preset, nil = leave as is.
    let echoCancellation: Bool?
}

/// Factory presets (v2): business/calls, gaming, streaming and the fun creative filters, all
/// built from the built-in gate/EQ/compressor/leveler/de-esser/limiter (+ chorus/pitch/reverb/
/// delay for the creative ones) stages. Every chain lists its stages in the same canonical
/// signal-flow order -- `FXNodeKind`'s declaration order -- with the core dynamics stages
/// (gate, EQ, compressor, leveler, de-esser) always present (disabled if unused) so
/// `FXMacros`/`AutoSetup` can always find "the compressor slot" by kind without special-casing
/// which presets happen to use it; the creative stages (chorus, pitch shift, reverb, delay) are
/// only present in presets that actually use them (see `stages(...)` below).
///
/// Targets: speech loudness -16 LUFS for streaming, -18 LUFS for calls/gaming (the leveler's
/// `target`); true-peak ceiling -1 dBTP (the limiter's `ceiling`, enforced by its own 4x
/// oversampled true-peak detector); a gate in Voice mode for gaming/office, where background
/// chatter and key clicks must not hold the mic open; a 70-100 Hz high-pass by use (higher for
/// noisier/thinner sources); a de-esser wherever the EQ adds brightness. Verified numerically in
/// `FactoryPresetsTests`.
enum FactoryPresets {
    static let all: [FactoryPreset] = [
        meetingNatural, presentationWebinar, openOffice, laptopMicRescue,
        headsetGaming, speakersGaming,
        streamBroadcast, podcast, lateNight,
        chipmunk, deepVoice, robot, telephone, radioAnnouncer, cathedral, dreamy, spaceStation,
    ]

    static func preset(id: String) -> FactoryPreset? { all.first { $0.id == id } }

    // MARK: - Business

    private static let meetingNatural = FactoryPreset(
        id: "meeting-natural", name: "Meeting – Natural", category: .business,
        summary: "Clear, natural speech for video calls -- light cleanup that doesn't sound processed.",
        symbol: "person.wave.2.fill",
        preset: EffectsPreset(isEnabled: true, nodes: stages(
            gate: gateNode(threshold: -45, hysteresis: 4, voiceSensitivity: 55, attack: 2, hold: 150, release: 220,
                           range: -18, keyHighPass: 90),
            eq: eqNode(bands: [
                EQBandConfig(id: 0, type: .highpass, frequencyHz: 90, gainDB: 0, q: 0.707),
                EQBandConfig(id: 1, type: .peaking, frequencyHz: 220, gainDB: -1, q: 0.8),
                EQBandConfig(id: 2, type: .peaking, frequencyHz: 3000, gainDB: 1.5, q: 1.0),
                EQBandConfig(id: 3, type: .highshelf, frequencyHz: 9000, gainDB: 1, q: 0.7),
            ]),
            compressor: compressorNode(threshold: -22, ratio: 2.2, attack: 15, release: 180, makeup: 2),
            leveler: levelerNode(target: -18, maxBoost: 16, maxCut: 10, speed: 900),
            deEsser: deEsserNode(frequency: 6500, threshold: -28, range: 5),
            limiter: limiterNode(ceiling: -1, release: 60)
        )),
        noiseSuppression: NoiseSuppressionSettings(isEnabled: true, engine: .fastenhancer, maxReductionDB: -40),
        echoCancellation: true
    )

    private static let presentationWebinar = FactoryPreset(
        id: "presentation-webinar", name: "Presentation / Webinar", category: .business,
        summary: "Louder, more authoritative delivery for presenting to a room or webinar audience.",
        symbol: "megaphone.fill",
        preset: EffectsPreset(isEnabled: true, nodes: stages(
            gate: gateNode(threshold: -42, hysteresis: 4, voiceSensitivity: 55, attack: 2, hold: 150, release: 200,
                           range: -20, keyHighPass: 85),
            eq: eqNode(bands: [
                EQBandConfig(id: 0, type: .highpass, frequencyHz: 85, gainDB: 0, q: 0.707),
                EQBandConfig(id: 1, type: .peaking, frequencyHz: 150, gainDB: 1.5, q: 0.9),
                EQBandConfig(id: 2, type: .peaking, frequencyHz: 350, gainDB: -1.5, q: 1.1),
                EQBandConfig(id: 3, type: .peaking, frequencyHz: 3200, gainDB: 2.5, q: 1.0),
                EQBandConfig(id: 4, type: .highshelf, frequencyHz: 9000, gainDB: 1.5, q: 0.7),
            ]),
            compressor: compressorNode(threshold: -20, ratio: 3, attack: 10, release: 150, makeup: 3),
            leveler: levelerNode(target: -18, maxBoost: 16, maxCut: 10, speed: 1200),
            deEsser: deEsserNode(frequency: 6500, threshold: -26, range: 6),
            limiter: limiterNode(ceiling: -1, release: 55)
        )),
        noiseSuppression: NoiseSuppressionSettings(isEnabled: true, engine: .fastenhancer, maxReductionDB: -45),
        echoCancellation: true
    )

    private static let openOffice = FactoryPreset(
        id: "open-office", name: "Open Office", category: .business,
        summary: "Aggressive noise control for busy shared spaces -- keyboards, chatter, HVAC.",
        symbol: "building.2.fill",
        preset: EffectsPreset(isEnabled: true, nodes: stages(
            gate: gateNode(threshold: -38, hysteresis: 6, voiceSensitivity: 70, attack: 1, hold: 100, release: 150,
                           range: -30, keyHighPass: 100),
            eq: eqNode(bands: [
                EQBandConfig(id: 0, type: .highpass, frequencyHz: 100, gainDB: 0, q: 0.707),
                EQBandConfig(id: 1, type: .peaking, frequencyHz: 300, gainDB: -2, q: 1.1),
                EQBandConfig(id: 2, type: .peaking, frequencyHz: 3000, gainDB: 1.5, q: 1.0),
            ]),
            compressor: compressorNode(threshold: -22, ratio: 3, attack: 10, release: 150, makeup: 3),
            leveler: levelerNode(target: -18, maxBoost: 16, maxCut: 10, speed: 900),
            deEsser: deEsserNode(frequency: 6500, threshold: -28, range: 6),
            limiter: limiterNode(ceiling: -1, release: 55)
        )),
        noiseSuppression: NoiseSuppressionSettings(isEnabled: true, engine: .dpdfnet, maxReductionDB: -55),
        echoCancellation: false
    )

    private static let laptopMicRescue = FactoryPreset(
        id: "laptop-mic-rescue", name: "Laptop Mic Rescue", category: .business,
        summary: "Makes a built-in laptop mic usable: aggressive cleanup, warmth and de-essing for thin, hissy capture.",
        symbol: "laptopcomputer",
        preset: EffectsPreset(isEnabled: true, nodes: stages(
            gate: gateNode(threshold: -40, hysteresis: 5, voiceSensitivity: 60, attack: 1, hold: 120, release: 180,
                           range: -24, keyHighPass: 100),
            eq: eqNode(bands: [
                EQBandConfig(id: 0, type: .highpass, frequencyHz: 100, gainDB: 0, q: 0.707),
                EQBandConfig(id: 1, type: .peaking, frequencyHz: 150, gainDB: 2, q: 0.9),
                EQBandConfig(id: 2, type: .peaking, frequencyHz: 300, gainDB: -2, q: 1.1),
                EQBandConfig(id: 3, type: .peaking, frequencyHz: 3500, gainDB: 2, q: 1.0),
                EQBandConfig(id: 4, type: .peaking, frequencyHz: 6000, gainDB: -1.5, q: 1.2),
            ]),
            compressor: compressorNode(threshold: -24, ratio: 3.5, attack: 8, release: 150, makeup: 4),
            leveler: levelerNode(target: -18, maxBoost: 16, maxCut: 10, speed: 900),
            deEsser: deEsserNode(frequency: 6000, threshold: -24, range: 8),
            limiter: limiterNode(ceiling: -1, release: 55)
        )),
        noiseSuppression: NoiseSuppressionSettings(isEnabled: true, engine: .dpdfnet, maxReductionDB: -55),
        echoCancellation: true
    )

    // MARK: - Gaming

    private static let headsetGaming = FactoryPreset(
        id: "headset-gaming", name: "Headset – Gaming", category: .gaming,
        summary: "Punchy, present voice for teammates over a gaming headset mic, with a tight noise gate.",
        symbol: "headphones",
        preset: EffectsPreset(isEnabled: true, nodes: stages(
            gate: gateNode(threshold: -42, hysteresis: 5, voiceSensitivity: 60, attack: 1, hold: 100, release: 150,
                           range: -26, keyHighPass: 90),
            eq: eqNode(bands: [
                EQBandConfig(id: 0, type: .highpass, frequencyHz: 90, gainDB: 0, q: 0.707),
                EQBandConfig(id: 1, type: .peaking, frequencyHz: 300, gainDB: -1.5, q: 1.1),
                EQBandConfig(id: 2, type: .peaking, frequencyHz: 3200, gainDB: 2, q: 1.0),
            ]),
            compressor: compressorNode(threshold: -20, ratio: 3.5, attack: 8, release: 140, makeup: 3),
            leveler: levelerNode(target: -18, maxBoost: 16, maxCut: 10, speed: 1200),
            deEsser: deEsserNode(frequency: 6500, threshold: -28, range: 6),
            limiter: limiterNode(ceiling: -1, release: 50)
        )),
        noiseSuppression: NoiseSuppressionSettings(isEnabled: true, engine: .fastenhancer, maxReductionDB: -45),
        echoCancellation: false
    )

    private static let speakersGaming = FactoryPreset(
        id: "speakers-gaming", name: "Speakers – Gaming", category: .gaming,
        summary: "For gaming on desktop speakers -- echo cancellation keeps game audio out of your mic.",
        symbol: "hifispeaker.2.fill",
        preset: EffectsPreset(isEnabled: true, nodes: stages(
            gate: gateNode(threshold: -40, hysteresis: 5, voiceSensitivity: 60, attack: 1, hold: 100, release: 150,
                           range: -26, keyHighPass: 90),
            eq: eqNode(bands: [
                EQBandConfig(id: 0, type: .highpass, frequencyHz: 90, gainDB: 0, q: 0.707),
                EQBandConfig(id: 1, type: .peaking, frequencyHz: 300, gainDB: -1.5, q: 1.1),
                EQBandConfig(id: 2, type: .peaking, frequencyHz: 3200, gainDB: 2, q: 1.0),
            ]),
            compressor: compressorNode(threshold: -20, ratio: 3.5, attack: 8, release: 140, makeup: 3),
            leveler: levelerNode(target: -18, maxBoost: 16, maxCut: 10, speed: 1200),
            deEsser: deEsserNode(frequency: 6500, threshold: -28, range: 6),
            limiter: limiterNode(ceiling: -1, release: 50)
        )),
        noiseSuppression: NoiseSuppressionSettings(isEnabled: true, engine: .fastenhancer, maxReductionDB: -45),
        echoCancellation: true
    )

    // MARK: - Streaming

    private static let streamBroadcast = FactoryPreset(
        id: "stream-broadcast", name: "Stream / Broadcast", category: .streaming,
        summary: "Loud, polished broadcast voice for live streaming, mixed against game or music audio.",
        symbol: "antenna.radiowaves.left.and.right",
        preset: EffectsPreset(isEnabled: true, nodes: stages(
            gate: gateNode(threshold: -42, hysteresis: 4, voiceSensitivity: 50, attack: 2, hold: 150, release: 200,
                           range: -20, keyHighPass: 80),
            eq: eqNode(bands: [
                EQBandConfig(id: 0, type: .highpass, frequencyHz: 80, gainDB: 0, q: 0.707),
                EQBandConfig(id: 1, type: .peaking, frequencyHz: 300, gainDB: -2, q: 1.1),
                EQBandConfig(id: 2, type: .peaking, frequencyHz: 3500, gainDB: 2.5, q: 1.0),
                EQBandConfig(id: 3, type: .highshelf, frequencyHz: 9000, gainDB: 2, q: 0.7),
            ]),
            compressor: compressorNode(threshold: -20, ratio: 4, attack: 8, release: 140, makeup: 4),
            leveler: levelerNode(target: -16, maxBoost: 16, maxCut: 10, speed: 1200),
            deEsser: deEsserNode(frequency: 6500, threshold: -26, range: 7),
            limiter: limiterNode(ceiling: -1, release: 50)
        )),
        noiseSuppression: NoiseSuppressionSettings(isEnabled: true, engine: .fastenhancer, maxReductionDB: -45),
        echoCancellation: false
    )

    private static let podcast = FactoryPreset(
        id: "podcast", name: "Podcast", category: .streaming,
        summary: "Warm, consistent podcast voice -- gentle compression and loudness matching for long-form talk.",
        symbol: "mic.fill",
        preset: EffectsPreset(isEnabled: true, nodes: stages(
            gate: gateNode(threshold: -40, hysteresis: 4, voiceSensitivity: 50, attack: 2, hold: 150, release: 220,
                           range: -16, keyHighPass: 80),
            eq: eqNode(bands: [
                EQBandConfig(id: 0, type: .highpass, frequencyHz: 80, gainDB: 0, q: 0.707),
                EQBandConfig(id: 1, type: .peaking, frequencyHz: 150, gainDB: 1.5, q: 0.9),
                EQBandConfig(id: 2, type: .peaking, frequencyHz: 350, gainDB: -1, q: 1.1),
                EQBandConfig(id: 3, type: .peaking, frequencyHz: 3000, gainDB: 1.5, q: 1.0),
                EQBandConfig(id: 4, type: .highshelf, frequencyHz: 8000, gainDB: 1, q: 0.7),
            ]),
            compressor: compressorNode(threshold: -22, ratio: 2.5, attack: 15, release: 200, makeup: 2.5),
            leveler: levelerNode(target: -16, maxBoost: 16, maxCut: 10, speed: 2000),
            deEsser: deEsserNode(frequency: 6500, threshold: -30, range: 5),
            limiter: limiterNode(ceiling: -1, release: 60)
        )),
        noiseSuppression: NoiseSuppressionSettings(isEnabled: true, engine: .fastenhancer, maxReductionDB: -35),
        echoCancellation: false
    )

    private static let lateNight = FactoryPreset(
        id: "late-night", name: "Late Night", category: .streaming,
        summary: "Intimate, hushed late-night stream voice -- tamed sibilance, soft dynamics, quiet-room friendly.",
        symbol: "moon.stars.fill",
        preset: EffectsPreset(isEnabled: true, nodes: stages(
            gate: gateNode(threshold: -48, hysteresis: 3, voiceSensitivity: 45, attack: 2, hold: 180, release: 250,
                           range: -14, keyHighPass: 70),
            eq: eqNode(bands: [
                EQBandConfig(id: 0, type: .highpass, frequencyHz: 70, gainDB: 0, q: 0.707),
                EQBandConfig(id: 1, type: .peaking, frequencyHz: 150, gainDB: 2, q: 0.9),
                EQBandConfig(id: 2, type: .peaking, frequencyHz: 3000, gainDB: 1, q: 1.0),
                EQBandConfig(id: 3, type: .highshelf, frequencyHz: 8000, gainDB: 1, q: 0.7),
            ]),
            compressor: compressorNode(threshold: -26, ratio: 2, attack: 20, release: 220, makeup: 1.5),
            leveler: levelerNode(target: -16, maxBoost: 16, maxCut: 8, speed: 1800),
            deEsser: deEsserNode(frequency: 6500, threshold: -32, range: 4),
            limiter: limiterNode(ceiling: -1, release: 65)
        )),
        noiseSuppression: NoiseSuppressionSettings(isEnabled: true, engine: .dpdfnet, maxReductionDB: -50),
        echoCancellation: false
    )

    // MARK: - Creative (the fun ones, re-tuned for the new stages)

    private static let chipmunk = FactoryPreset(
        id: "chipmunk", name: "Chipmunk", category: .creative,
        summary: "High-pitched helium voice.", symbol: "hare.fill",
        preset: EffectsPreset(isEnabled: true, nodes: stages(
            pitchShift: pitchShiftNode(semitones: 12, formant: -2, preserveFormants: 0, mix: 100),
            limiter: limiterNode(ceiling: -1, release: 50)
        )),
        noiseSuppression: nil, echoCancellation: nil
    )

    private static let deepVoice = FactoryPreset(
        id: "deep-voice", name: "Deep Voice", category: .creative,
        summary: "Lower, more resonant voice.", symbol: "tortoise.fill",
        preset: EffectsPreset(isEnabled: true, nodes: stages(
            gate: gateNode(threshold: -40, hysteresis: 4, range: -12, keyHighPass: 70),
            eq: eqNode(bands: [
                EQBandConfig(id: 0, type: .highpass, frequencyHz: 60, gainDB: 0, q: 0.7),
                EQBandConfig(id: 1, type: .peaking, frequencyHz: 150, gainDB: 3, q: 0.8),
                EQBandConfig(id: 2, type: .peaking, frequencyHz: 300, gainDB: 1, q: 1.0),
                EQBandConfig(id: 3, type: .peaking, frequencyHz: 3000, gainDB: -2, q: 1.0),
                EQBandConfig(id: 4, type: .highshelf, frequencyHz: 8000, gainDB: -3, q: 0.7),
            ]),
            compressor: compressorNode(threshold: -20, ratio: 3, attack: 15, release: 200, makeup: 2.5),
            pitchShift: pitchShiftNode(semitones: -5, formant: -2, preserveFormants: 1, mix: 100),
            limiter: limiterNode(ceiling: -1.5, release: 55)
        )),
        noiseSuppression: nil, echoCancellation: nil
    )

    private static let robot = FactoryPreset(
        id: "robot", name: "Robot", category: .creative,
        summary: "Robotic, metallic timbre.", symbol: "cpu",
        preset: EffectsPreset(isEnabled: true, nodes: stages(
            chorus: chorusNode(rate: 5.5, depth: 0.4, mix: 65),
            pitchShift: pitchShiftNode(semitones: -6, formant: -4, preserveFormants: 0, mix: 75),
            reverb: reverbNode(size: 15, damping: 85, preDelay: 0, mix: 25),
            limiter: limiterNode(ceiling: -1, release: 50)
        )),
        noiseSuppression: nil, echoCancellation: nil
    )

    private static let telephone = FactoryPreset(
        id: "telephone", name: "Telephone", category: .creative,
        summary: "Classic narrow-band telephone call sound.", symbol: "phone.fill",
        preset: EffectsPreset(isEnabled: true, nodes: stages(
            eq: eqNode(bands: [
                EQBandConfig(id: 0, type: .highpass, frequencyHz: 300, gainDB: 0, q: 0.7, slopeDBPerOctave: 24),
                EQBandConfig(id: 1, type: .peaking, frequencyHz: 800, gainDB: 3, q: 0.8),
                EQBandConfig(id: 2, type: .peaking, frequencyHz: 2000, gainDB: 4, q: 1.0),
                EQBandConfig(id: 3, type: .lowpass, frequencyHz: 3400, gainDB: 0, q: 0.7, slopeDBPerOctave: 24),
            ]),
            compressor: compressorNode(threshold: -15, ratio: 8, attack: 5, release: 100, makeup: 4),
            limiter: limiterNode(ceiling: -2, release: 50)
        )),
        noiseSuppression: nil, echoCancellation: nil
    )

    private static let radioAnnouncer = FactoryPreset(
        id: "radio-announcer", name: "Radio Announcer", category: .creative,
        summary: "Big, warm, radio-DJ broadcast voice.", symbol: "radio",
        preset: EffectsPreset(isEnabled: true, nodes: stages(
            gate: gateNode(threshold: -32, hysteresis: 4, range: -15, keyHighPass: 80),
            eq: eqNode(bands: [
                EQBandConfig(id: 0, type: .highpass, frequencyHz: 80, gainDB: 0, q: 0.7),
                EQBandConfig(id: 1, type: .peaking, frequencyHz: 180, gainDB: 3, q: 0.8),
                EQBandConfig(id: 2, type: .peaking, frequencyHz: 400, gainDB: -3, q: 1.2),
                EQBandConfig(id: 3, type: .peaking, frequencyHz: 3200, gainDB: 3, q: 0.9),
                EQBandConfig(id: 4, type: .highshelf, frequencyHz: 10000, gainDB: 2, q: 0.7),
            ]),
            compressor: compressorNode(threshold: -16, ratio: 5, attack: 10, release: 120, makeup: 5),
            leveler: levelerNode(target: -16, maxBoost: 16, maxCut: 10, speed: 1200),
            deEsser: deEsserNode(frequency: 6500, threshold: -24, range: 8),
            reverb: reverbNode(size: 30, damping: 60, preDelay: 10, mix: 6),
            limiter: limiterNode(ceiling: -1, release: 50)
        )),
        noiseSuppression: nil, echoCancellation: nil
    )

    private static let cathedral = FactoryPreset(
        id: "cathedral", name: "Cathedral", category: .creative,
        summary: "Vast cathedral reverb trailing your voice.", symbol: "building.columns.fill",
        preset: EffectsPreset(isEnabled: true, nodes: stages(
            gate: gateNode(threshold: -45, hysteresis: 4, range: -10, keyHighPass: 70),
            compressor: compressorNode(threshold: -22, ratio: 2.5, attack: 15, release: 200, makeup: 2),
            reverb: reverbNode(size: 95, damping: 20, preDelay: 10, mix: 35),
            delay: delayNode(time: 120, feedback: 25, highCut: 8000, mix: 10),
            limiter: limiterNode(ceiling: -1.5, release: 60)
        )),
        noiseSuppression: nil, echoCancellation: nil
    )

    private static let dreamy = FactoryPreset(
        id: "dreamy", name: "Dreamy", category: .creative,
        summary: "Soft, swirling, dreamlike atmosphere.", symbol: "cloud.fill",
        preset: EffectsPreset(isEnabled: true, nodes: stages(
            chorus: chorusNode(rate: 0.5, depth: 4.0, mix: 50),
            reverb: reverbNode(size: 85, damping: 30, preDelay: 10, mix: 40),
            delay: delayNode(time: 400, feedback: 40, highCut: 8000, mix: 15),
            limiter: limiterNode(ceiling: -1.5, release: 60)
        )),
        noiseSuppression: nil, echoCancellation: nil
    )

    private static let spaceStation = FactoryPreset(
        id: "space-station", name: "Space Station", category: .creative,
        summary: "Distant, metallic, otherworldly radio chatter.", symbol: "sparkles",
        preset: EffectsPreset(isEnabled: true, nodes: stages(
            chorus: chorusNode(rate: 2.5, depth: 3.0, mix: 60),
            pitchShift: pitchShiftNode(semitones: -3, formant: -2, preserveFormants: 1, mix: 70),
            reverb: reverbNode(size: 90, damping: 15, preDelay: 10, mix: 45),
            delay: delayNode(time: 300, feedback: 50, highCut: 8000, mix: 20),
            limiter: limiterNode(ceiling: -1, release: 55)
        )),
        noiseSuppression: nil, echoCancellation: nil
    )
}

// MARK: - Stage builders (canonical signal-flow order, matching `FXNodeKind`'s declaration order)

/// Assembles a chain in `FXNodeKind`'s canonical order (gate, eq, compressor, leveler, deEsser,
/// chorus, pitchShift, reverb, delay, limiter); `gate`/`eq`/`compressor`/`leveler`/`deEsser`
/// are always present (disabled if not given) so `FXMacros`/`AutoSetup` can always find them by
/// kind. `chorus`/`pitchShift`/`reverb`/`delay` are omitted entirely (not included disabled)
/// unless given: a disabled node still runs its full DSP every block for the bypass crossfade
/// (see `FXChain.processSlot`), so a preset that never uses the creative stages (every
/// business/gaming/streaming preset) shouldn't pay for their FFT/convolution-based processing.
private func stages(
    gate: FXNodeConfig = gateNode(enabled: false),
    eq: FXNodeConfig = eqNode(bands: [], enabled: false),
    compressor: FXNodeConfig = compressorNode(enabled: false),
    leveler: FXNodeConfig = levelerNode(enabled: false),
    deEsser: FXNodeConfig = deEsserNode(enabled: false),
    chorus: FXNodeConfig? = nil,
    pitchShift: FXNodeConfig? = nil,
    reverb: FXNodeConfig? = nil,
    delay: FXNodeConfig? = nil,
    limiter: FXNodeConfig = limiterNode()
) -> [FXNodeConfig] {
    var nodes = [gate, eq, compressor, leveler, deEsser]
    if let chorus { nodes.append(chorus) }
    if let pitchShift { nodes.append(pitchShift) }
    if let reverb { nodes.append(reverb) }
    if let delay { nodes.append(delay) }
    nodes.append(limiter)
    return nodes
}

private func gateNode(mode: Float = 1, threshold: Float = -45, hysteresis: Float = 4, voiceSensitivity: Float = 50,
                      attack: Float = 1, hold: Float = 120, release: Float = 200, range: Float = -20,
                      keyHighPass: Float = 80, enabled: Bool = true) -> FXNodeConfig {
    FXNodeConfig(kind: .gate, enabled: enabled, params: [
        "mode": mode, "threshold": threshold, "hysteresis": hysteresis, "voiceSensitivity": voiceSensitivity,
        "attack": attack, "hold": hold, "release": release, "range": range, "keyHighPass": keyHighPass,
    ])
}

private func eqNode(bands: [EQBandConfig], outputGain: Float = 0, enabled: Bool = true) -> FXNodeConfig {
    FXNodeConfig(kind: .eq, enabled: enabled, params: ["outputGain": outputGain], eqBands: bands)
}

private func compressorNode(threshold: Float = -20, ratio: Float = 3, knee: Float = 6, attack: Float = 10,
                            release: Float = 150, detector: Float = 1, makeup: Float = 0, mix: Float = 100,
                            enabled: Bool = true) -> FXNodeConfig {
    FXNodeConfig(kind: .compressor, enabled: enabled, params: [
        "threshold": threshold, "ratio": ratio, "knee": knee, "attack": attack, "release": release,
        "detector": detector, "makeup": makeup, "mix": mix,
    ])
}

private func levelerNode(target: Float = -18, maxBoost: Float = 12, maxCut: Float = 12, speed: Float = 1500,
                         enabled: Bool = true) -> FXNodeConfig {
    FXNodeConfig(kind: .leveler, enabled: enabled, params: [
        "target": target, "maxBoost": maxBoost, "maxCut": maxCut, "speed": speed,
    ])
}

private func deEsserNode(frequency: Float = 6500, threshold: Float = -30, range: Float = 8, mode: Float = 0,
                         enabled: Bool = true) -> FXNodeConfig {
    FXNodeConfig(kind: .deEsser, enabled: enabled, params: [
        "frequency": frequency, "threshold": threshold, "range": range, "mode": mode,
    ])
}

private func chorusNode(rate: Float = 0.8, depth: Float = 1.5, mix: Float = 30, enabled: Bool = true) -> FXNodeConfig {
    FXNodeConfig(kind: .chorus, enabled: enabled, params: ["rate": rate, "depth": depth, "mix": mix])
}

private func pitchShiftNode(semitones: Float = 0, formant: Float = 0, preserveFormants: Float = 1, mix: Float = 100,
                            enabled: Bool = true) -> FXNodeConfig {
    FXNodeConfig(kind: .pitchShift, enabled: enabled, params: [
        "semitones": semitones, "formant": formant, "preserveFormants": preserveFormants, "mix": mix,
    ])
}

private func reverbNode(size: Float = 50, damping: Float = 50, preDelay: Float = 10, mix: Float = 15,
                        enabled: Bool = true) -> FXNodeConfig {
    FXNodeConfig(kind: .reverb, enabled: enabled, params: ["size": size, "damping": damping, "preDelay": preDelay, "mix": mix])
}

private func delayNode(time: Float = 250, feedback: Float = 30, highCut: Float = 8000, mix: Float = 25,
                       enabled: Bool = true) -> FXNodeConfig {
    FXNodeConfig(kind: .delay, enabled: enabled, params: ["time": time, "feedback": feedback, "highCut": highCut, "mix": mix])
}

private func limiterNode(inputGain: Float = 0, ceiling: Float = -1, release: Float = 60) -> FXNodeConfig {
    FXNodeConfig(kind: .limiter, enabled: true, params: ["inputGain": inputGain, "ceiling": ceiling, "release": release])
}

// MARK: - Named preset library (automation: auto-switch rules, Shortcuts, URL scheme)

/// A preset automation can refer to by a stable id, whether it's a factory preset or one the
/// user saved (`EffectsPresetManager`).
struct NamedPreset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isFactory: Bool
}

enum EffectsPresetLibrary {
    private static let savedPrefix = "saved:"

    /// Factory presets first (their stable slugs), then saved presets (by file name, prefixed
    /// so the two id spaces never collide).
    static func all() -> [NamedPreset] {
        let factory = FactoryPresets.all.map { NamedPreset(id: $0.id, name: $0.name, isFactory: true) }
        let saved = EffectsPresetManager.list().map { NamedPreset(id: savedPrefix + $0, name: $0, isFactory: false) }
        return factory + saved
    }

    /// Applies the preset named by `id` to `state`: for a factory preset, its node graph plus
    /// its recommended noise suppression and echo cancellation; for a saved preset, exactly
    /// what was saved. Returns false (no change made) if `id` doesn't resolve.
    @MainActor
    static func apply(id: String, to state: RoutingState) -> Bool {
        if let factory = FactoryPresets.preset(id: id) {
            var applied = factory.preset
            applied.isEnabled = true
            state.effectsPreset = applied
            if let noise = factory.noiseSuppression { state.noiseSuppression = noise }
            if let echo = factory.echoCancellation { state.noiseSuppression.echoCancellation = echo }
            state.save()
            return true
        }
        guard id.hasPrefix(savedPrefix), let loaded = EffectsPresetManager.load(name: String(id.dropFirst(savedPrefix.count))) else {
            return false
        }
        var applied = loaded
        applied.isEnabled = true
        state.effectsPreset = applied
        state.save()
        return true
    }
}
