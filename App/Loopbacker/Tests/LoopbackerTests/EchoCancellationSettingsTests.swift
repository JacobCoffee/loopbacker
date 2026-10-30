import Foundation
import Testing
@testable import Loopbacker

@Suite("Echo cancellation settings decoding")
struct EchoCancellationSettingsTests {
    @Test("NoiseSuppressionSettings.echoCancellation defaults to false and round-trips")
    func noiseSuppressionSettingsDefault() throws {
        #expect(NoiseSuppressionSettings().echoCancellation == false)

        var settings = NoiseSuppressionSettings()
        settings.echoCancellation = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(NoiseSuppressionSettings.self, from: data)
        #expect(decoded.echoCancellation == true)
    }

    @Test("A pre-echo-cancellation NoiseSuppressionSettings config (no echoCancellation key) decodes to false")
    func noiseSuppressionSettingsOldConfigDecodesFalse() throws {
        let oldConfigJSON = """
        {"isEnabled": true, "engine": "fastenhancer", "maxReductionDB": -42}
        """
        let decoded = try JSONDecoder().decode(NoiseSuppressionSettings.self, from: Data(oldConfigJSON.utf8))
        #expect(decoded.echoCancellation == false)
        // The keys that were present still decode correctly -- this isn't just falling back to
        // an all-defaults struct.
        #expect(decoded.isEnabled == true)
        #expect(decoded.maxReductionDB == -42)
    }

    @Test("AudioSource.echoCancellation defaults to true (opt-out) and round-trips")
    func audioSourceDefault() throws {
        let source = AudioSource(name: "Mic", channels: [AudioChannel(id: 0, label: "L")])
        #expect(source.echoCancellation == true)

        var optedOut = source
        optedOut.echoCancellation = false
        let data = try JSONEncoder().encode(optedOut)
        let decoded = try JSONDecoder().decode(AudioSource.self, from: data)
        #expect(decoded.echoCancellation == false)
    }

    @Test("A pre-echo-cancellation AudioSource config (no echoCancellation key) decodes to true")
    func audioSourceOldConfigDecodesTrue() throws {
        let oldConfigJSON = """
        {
          "id": "\(UUID().uuidString)",
          "name": "Mic",
          "icon": "mic.fill",
          "channels": [],
          "isEnabled": true,
          "isPassThrough": false,
          "deviceUID": "test-device",
          "sourceType": "device",
          "appBundleID": "",
          "noiseSuppression": false
        }
        """
        let decoded = try JSONDecoder().decode(AudioSource.self, from: Data(oldConfigJSON.utf8))
        #expect(decoded.echoCancellation == true)
        // Confirms this is genuinely decoding the old JSON, not just defaulting everything.
        #expect(decoded.noiseSuppression == false)
    }
}
