import Foundation
import Testing
@testable import Loopbacker

/// Verifies `EffectsPreset`'s v1 → v2 migration: flat gate/eq/compressor/... fields (no `nodes`
/// key) become an equivalent ordered `nodes` array.
@Suite("EffectsPreset v1 migration")
struct EffectsPresetMigrationTests {
    /// A real v1-shaped exported preset: the flat fields `AudioEffectsChain`/`EffectsPreset`
    /// used to persist, with no `version`/`nodes`/`appAudio` keys.
    private static let v1PresetJSON = """
    {
      "isEnabled": true,
      "gateEnabled": true, "gateThresholdDB": -41.5, "gateAttackMs": 3, "gateReleaseMs": 180, "gateReductionDB": -14,
      "eqEnabled": true,
      "eqBands": [
        {"id": 0, "type": "highpass", "frequencyHz": 90, "gainDB": 0, "q": 0.71},
        {"id": 1, "type": "peaking", "frequencyHz": 240, "gainDB": -1.5, "q": 0.9}
      ],
      "compressorEnabled": true, "compressorThresholdDB": -19, "compressorRatio": 4,
      "compressorAttackMs": 8, "compressorReleaseMs": 160, "compressorMakeupDB": 2.5,
      "deEsserEnabled": true, "deEsserFrequencyHz": 7200, "deEsserReductionDB": -9, "deEsserRatio": 3,
      "chorusEnabled": true, "chorusRate": 1.1, "chorusDepth": 2.2, "chorusMix": 0.4,
      "pitchShiftEnabled": true, "pitchSemitones": -3, "pitchMix": 0.6,
      "reverbEnabled": true, "reverbRoomSize": 0.6, "reverbDamping": 0.4, "reverbMix": 0.22,
      "delayEnabled": true, "delayTimeMs": 310, "delayFeedback": 0.35, "delayMix": 0.18,
      "limiterEnabled": true, "limiterCeilingDB": -1.2, "limiterReleaseMs": 75
    }
    """

    @Test("v1 JSON migrates to v2 with the expected node order")
    func migratedOrder() throws {
        let data = Self.v1PresetJSON.data(using: .utf8)!
        let preset = try JSONDecoder().decode(EffectsPreset.self, from: data)

        #expect(preset.version == 2)
        #expect(preset.isEnabled)
        #expect(preset.nodes.map(\.kind) == [
            .gate, .eq, .compressor, .deEsser, .chorus, .pitchShift, .reverb, .delay, .limiter,
        ])
        // Every migrated stage keeps its v1 enabled flag.
        #expect(preset.nodes.allSatisfy { $0.enabled })
    }

    @Test("Gate migrates with Level mode (old behaviour) and its v1 values")
    func gateValues() throws {
        let preset = try JSONDecoder().decode(EffectsPreset.self, from: Self.v1PresetJSON.data(using: .utf8)!)
        let gate = preset.nodes[0]
        #expect(gate.kind == .gate)
        #expect(gate.params["mode"] == 0) // Level, not Voice: matches v1's only behaviour.
        #expect(gate.params["threshold"] == -41.5)
        #expect(gate.params["attack"] == 3)
        #expect(gate.params["release"] == 180)
        #expect(gate.params["range"] == -14) // v1's gateReductionDB -> v2's range.
        #expect(gate.params["hold"] == 0)
        #expect(gate.params["hysteresis"] == 0)
    }

    @Test("EQ bands carry over unchanged")
    func eqBands() throws {
        let preset = try JSONDecoder().decode(EffectsPreset.self, from: Self.v1PresetJSON.data(using: .utf8)!)
        let eq = preset.nodes[1]
        #expect(eq.kind == .eq)
        #expect(eq.eqBands?.count == 2)
        #expect(eq.eqBands?[0].type == .highpass)
        #expect(eq.eqBands?[0].frequencyHz == 90)
        #expect(eq.eqBands?[1].gainDB == -1.5)
    }

    @Test("Compressor migrates with knee 0 and Peak detector (old behaviour)")
    func compressorValues() throws {
        let preset = try JSONDecoder().decode(EffectsPreset.self, from: Self.v1PresetJSON.data(using: .utf8)!)
        let compressor = preset.nodes[2]
        #expect(compressor.kind == .compressor)
        #expect(compressor.params["threshold"] == -19)
        #expect(compressor.params["ratio"] == 4)
        #expect(compressor.params["attack"] == 8)
        #expect(compressor.params["release"] == 160)
        #expect(compressor.params["makeup"] == 2.5)
        #expect(compressor.params["knee"] == 0)
        #expect(compressor.params["detector"] == 0) // Peak
        #expect(compressor.params["mix"] == 100)
    }

    @Test("De-Esser migrates with the hardcoded -22 dB threshold and split-band mode, range negated")
    func deEsserValues() throws {
        let preset = try JSONDecoder().decode(EffectsPreset.self, from: Self.v1PresetJSON.data(using: .utf8)!)
        let deEsser = preset.nodes[3]
        #expect(deEsser.kind == .deEsser)
        #expect(deEsser.params["frequency"] == 7200)
        #expect(deEsser.params["threshold"] == -22)
        #expect(deEsser.params["range"] == 9) // -deEsserReductionDB (-(-9) = 9)
        #expect(deEsser.params["mode"] == 0) // split-band
    }

    @Test("Chorus/Pitch/Reverb/Delay mix fields scale from 0...1 to 0...100")
    func percentScaling() throws {
        let preset = try JSONDecoder().decode(EffectsPreset.self, from: Self.v1PresetJSON.data(using: .utf8)!)
        let chorus = preset.nodes[4]
        #expect(chorus.params["rate"] == 1.1)
        #expect(chorus.params["depth"] == 2.2)
        #expect(abs((chorus.params["mix"] ?? 0) - 40) < 0.001)

        let pitch = preset.nodes[5]
        #expect(pitch.params["semitones"] == -3)
        #expect(pitch.params["preserveFormants"] == 1) // On
        #expect(abs((pitch.params["mix"] ?? 0) - 60) < 0.001)

        let reverb = preset.nodes[6]
        #expect(abs((reverb.params["size"] ?? 0) - 60) < 0.001)
        #expect(abs((reverb.params["damping"] ?? 0) - 40) < 0.001)
        #expect(reverb.params["preDelay"] == 0)
        #expect(abs((reverb.params["mix"] ?? 0) - 22) < 0.001)

        let delay = preset.nodes[7]
        #expect(delay.params["time"] == 310)
        #expect(abs((delay.params["feedback"] ?? 0) - 35) < 0.001)
        #expect(abs((delay.params["mix"] ?? 0) - 18) < 0.001)
    }

    @Test("Limiter carries ceiling and release over directly")
    func limiterValues() throws {
        let preset = try JSONDecoder().decode(EffectsPreset.self, from: Self.v1PresetJSON.data(using: .utf8)!)
        let limiter = preset.nodes[8]
        #expect(limiter.params["ceiling"] == -1.2)
        #expect(limiter.params["release"] == 75)
    }

    @Test("A v1 RoutingConfig (nested effectsPreset) migrates the same way")
    func nestedInRoutingConfig() throws {
        let routingConfigJSON = """
        {
          "sources": [], "outputChannels": [], "routes": [],
          "effectsPreset": \(Self.v1PresetJSON)
        }
        """
        let config = try JSONDecoder().decode(RoutingConfig.self, from: routingConfigJSON.data(using: .utf8)!)
        #expect(config.effectsPreset.version == 2)
        #expect(config.effectsPreset.nodes.map(\.kind).first == .gate)
        #expect(config.effectsPreset.nodes.count == 9)
    }

    @Test("v2 JSON round-trips without re-migrating")
    func v2RoundTrip() throws {
        let original = EffectsPreset.broadcastVoice
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EffectsPreset.self, from: data)
        #expect(decoded == original)
        #expect(decoded.version == 2)
    }
}
