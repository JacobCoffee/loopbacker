import Foundation
import Testing
@testable import Loopbacker

@Suite("SoundboardItem")
struct SoundboardItemTests {
    /// A `soundboard.json` entry exactly as the pre-trim/fade/loudness-matching app wrote it:
    /// only `id`, `name`, `emoji`, `fileBookmark`, `volume`, `sortIndex`.
    private static let legacyJSON = """
    {
        "id": "8C1B2F3E-0A4D-4E8C-9E3F-1A2B3C4D5E6F",
        "name": "Airhorn",
        "emoji": "📣",
        "fileBookmark": "AAE=",
        "volume": 0.75,
        "sortIndex": 3
    }
    """

    @Test("Existing soundboard.json entries decode unchanged, with sensible defaults")
    func decodesLegacyEntryUnchanged() throws {
        let data = Self.legacyJSON.data(using: .utf8)!
        let item = try JSONDecoder().decode(SoundboardItem.self, from: data)

        #expect(item.name == "Airhorn")
        #expect(item.emoji == "📣")
        #expect(item.volume == 0.75)
        #expect(item.sortIndex == 3)

        // New fields fall back to behavior-preserving defaults.
        #expect(item.trimStart == 0)
        #expect(item.trimEnd == nil)
        #expect(item.fadeInSeconds == 0)
        #expect(item.fadeOutSeconds == 0)
        #expect(item.playMode == .oneShot)
        #expect(item.chokeGroup == nil)
        #expect(item.retrigger == .restart)
        #expect(item.outputTarget == .virtualMicAndSpeakers) // matches the old always-both behavior
        #expect(item.loudnessGainOffsetDB == nil) // not yet measured
    }

    @Test("A full array of legacy entries decodes without throwing")
    func decodesLegacyArray() throws {
        let data = "[\(Self.legacyJSON), \(Self.legacyJSON)]".data(using: .utf8)!
        let items = try JSONDecoder().decode([SoundboardItem].self, from: data)
        #expect(items.count == 2)
    }

    @Test("Round-trips through encode/decode with new fields populated")
    func roundTripsNewFields() throws {
        var item = SoundboardItem(name: "Clip", fileBookmark: Data([0, 1, 2]))
        item.trimStart = 0.5
        item.trimEnd = 3.2
        item.fadeInSeconds = 0.1
        item.fadeOutSeconds = 0.2
        item.playMode = .loop
        item.chokeGroup = "reactions"
        item.retrigger = .layer
        item.outputTarget = .virtualMicOnly
        item.loudnessGainOffsetDB = -4.5

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(SoundboardItem.self, from: data)
        #expect(decoded == item)
    }

    @Test("A saved plain bookmark resolves back to its file")
    func resolvesPlainBookmark() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pad-\(UUID().uuidString).wav")
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // Boards saved by earlier versions hold plain bookmarks; resolving them as
        // security-scoped fails, which left every pad unplayable.
        let item = SoundboardItem(name: "Pad", fileBookmark: try url.bookmarkData())
        #expect(item.resolveURL()?.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path)
    }

    @Test("Two clips mastered 10 dB apart get gain offsets that bring them to matching loudness")
    func loudnessMatchingClosesA10dBGap() {
        let sampleRate = 48000.0
        let loud = sineStereo(dBFS: -10, seconds: 2, sampleRate: sampleRate)
        let quiet = sineStereo(dBFS: -20, seconds: 2, sampleRate: sampleRate)

        let loudLUFS = loud.withUnsafeBufferPointer {
            LoudnessMeter.integratedLoudness(samples: $0.baseAddress!, frames: loud.count / 2, channels: 2, sampleRate: sampleRate)
        }
        let quietLUFS = quiet.withUnsafeBufferPointer {
            LoudnessMeter.integratedLoudness(samples: $0.baseAddress!, frames: quiet.count / 2, channels: 2, sampleRate: sampleRate)
        }
        // The two source clips really are ~10 dB apart before matching.
        #expect(abs((loudLUFS - quietLUFS) - 10) < 0.5)

        let loudOffsetDB = SoundboardItem.loudnessMatchTargetLUFS - loudLUFS
        let quietOffsetDB = SoundboardItem.loudnessMatchTargetLUFS - quietLUFS

        // Apply each clip's offset (as SoundboardPlayer does) and re-measure: they should now
        // match within a small tolerance.
        let loudMatched = applyGain(loud, dB: loudOffsetDB)
        let quietMatched = applyGain(quiet, dB: quietOffsetDB)
        let loudMatchedLUFS = loudMatched.withUnsafeBufferPointer {
            LoudnessMeter.integratedLoudness(samples: $0.baseAddress!, frames: loudMatched.count / 2, channels: 2, sampleRate: sampleRate)
        }
        let quietMatchedLUFS = quietMatched.withUnsafeBufferPointer {
            LoudnessMeter.integratedLoudness(samples: $0.baseAddress!, frames: quietMatched.count / 2, channels: 2, sampleRate: sampleRate)
        }
        #expect(abs(loudMatchedLUFS - quietMatchedLUFS) < 0.2)
        #expect(abs(loudMatchedLUFS - SoundboardItem.loudnessMatchTargetLUFS) < 0.5)
    }

    @Test("A mono file's measured loudness matches stereo-duplicated playback, not its native single channel")
    func measuresMonoFileAsPlaybackDuplicatesIt() throws {
        // BS.1770 sums weighted energy across channels: duplicating a mono signal to both
        // playback channels (as `SoundboardPlayer` always does) measures ~3 LU louder than the
        // same content on its native single channel. If import-time measurement used the file's
        // native mono layout instead of the played-back stereo buffer, every mono pad's gain
        // offset would under-correct by that ~3 LU, leaving it audibly hot once played.
        let sampleRate = 48000.0
        let mono = sineMono(dBFS: -20, seconds: 2, sampleRate: sampleRate)
        let monoOnlyLUFS = mono.withUnsafeBufferPointer {
            LoudnessMeter.integratedLoudness(samples: $0.baseAddress!, frames: mono.count, channels: 1, sampleRate: sampleRate)
        }

        let url = try writeMonoWAV(mono, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoded = try #require(SoundboardPlayer.DecodedBuffer.decode(fileAt: url))
        defer { decoded.samples.deallocate() }
        let playbackLUFS = LoudnessMeter.integratedLoudness(
            samples: decoded.samples, frames: Int(decoded.frameCount), channels: Int(decoded.channelCount),
            sampleRate: decoded.sampleRate
        )

        #expect(abs((playbackLUFS - monoOnlyLUFS) - 3.01) < 0.3)
    }

    // MARK: - Fixtures

    private func sineStereo(dBFS: Double, seconds: Double, sampleRate: Double) -> [Float] {
        let amplitude = pow(10, dBFS / 20)
        let frameCount = Int(sampleRate * seconds)
        var samples = [Float](repeating: 0, count: frameCount * 2)
        for n in 0..<frameCount {
            let s = Float(amplitude * sin(2 * Double.pi * 1000 * Double(n) / sampleRate))
            samples[n * 2] = s
            samples[n * 2 + 1] = s
        }
        return samples
    }

    private func applyGain(_ samples: [Float], dB: Float) -> [Float] {
        let linear = pow(10, dB / 20)
        return samples.map { $0 * linear }
    }

    private func sineMono(dBFS: Double, seconds: Double, sampleRate: Double) -> [Float] {
        let amplitude = pow(10, dBFS / 20)
        let frameCount = Int(sampleRate * seconds)
        return (0..<frameCount).map { n in
            Float(amplitude * sin(2 * Double.pi * 1000 * Double(n) / sampleRate))
        }
    }

    /// Writes a 16-bit PCM mono WAV to a temp file, for tests that need a real file
    /// `AVAudioFile` can decode (not just raw sample arrays).
    private func writeMonoWAV(_ samples: [Float], sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        var data = Data()
        let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32767) }
        let dataSize = UInt32(pcm.count * 2)
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + dataSize).littleEndian)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        append(UInt32(16).littleEndian)
        append(UInt16(1).littleEndian) // PCM
        append(UInt16(1).littleEndian) // mono
        append(UInt32(sampleRate).littleEndian)
        append(UInt32(sampleRate * 2).littleEndian) // byte rate
        append(UInt16(2).littleEndian) // block align
        append(UInt16(16).littleEndian) // bits per sample
        data.append(contentsOf: "data".utf8)
        append(dataSize.littleEndian)
        for sample in pcm { append(sample.littleEndian) }
        try data.write(to: url)
        return url
    }
}
