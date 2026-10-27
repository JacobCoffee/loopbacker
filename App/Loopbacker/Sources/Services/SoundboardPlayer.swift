import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import os.log

private let sbLogger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "SoundboardPlayer")

/// Plays audio files through the Loopbacker virtual device so they appear
/// in Discord, Zoom, OBS, etc. Each sound gets its own AUHAL output unit;
/// CoreAudio handles mixing multiple simultaneous sounds on the device side.
///
/// Playback bookkeeping lives on the main actor. Decoding and unit setup run on
/// `SoundboardEngine` so slow files and CoreAudio queries never block the UI.
@MainActor
final class SoundboardPlayer: ObservableObject {
    @Published var playingIDs: Set<UUID> = []
    @Published var meterLevel: Float = 0.0  // global output level for UI

    /// Global volume multiplier (0...1)
    var globalVolume: Float = 1.0

    private var activePlaybacks: [UUID: PlaybackContext] = [:]
    /// Sounds whose units are still being prepared; removing an ID cancels its start.
    private var startingIDs: Set<UUID> = []
    private let engine = SoundboardEngine()

    // MARK: - Decoded audio buffer

    /// Immutable once decoded; render callbacks only read `samples`.
    fileprivate struct DecodedBuffer: @unchecked Sendable {
        let samples: UnsafeMutablePointer<Float>  // interleaved stereo float32
        let frameCount: UInt32
        let channelCount: UInt32
        let sampleRate: Float64
    }

    // MARK: - Per-sound playback context

    /// One per audio unit — each has its own read position into the shared buffer
    fileprivate class RenderState {
        var buffer: DecodedBuffer
        var readPosition: UInt32 = 0
        var volume: Float = 1.0
        var globalVolume: Float = 1.0
        var done: Bool = false
        var meterLevel: Float = 0.0

        init(buffer: DecodedBuffer, volume: Float, globalVolume: Float) {
            self.buffer = buffer
            self.volume = volume
            self.globalVolume = globalVolume
        }
    }

    /// Built by the engine, then owned by the main actor. Render callbacks reach the
    /// states through retained raw pointers, never through this object.
    fileprivate final class PlaybackContext: @unchecked Sendable {
        var speakerUnit: AudioComponentInstance?
        var loopbackUnit: AudioComponentInstance?
        var speakerState: RenderState?
        var loopbackState: RenderState?
        let itemID: UUID

        var done: Bool { speakerState?.done ?? true }
        var meterLevel: Float { speakerState?.meterLevel ?? 0 }

        init(itemID: UUID) { self.itemID = itemID }
    }

    // MARK: - Public API

    func play(item: SoundboardItem) {
        // Toggle: a second press stops the sound, including while it is still being prepared.
        if activePlaybacks[item.id] != nil || startingIDs.contains(item.id) {
            stop(id: item.id)
            return
        }

        startingIDs.insert(item.id)
        let volume = globalVolume
        Task {
            let ctx = await engine.prepare(item: item, globalVolume: volume)
            let stillWanted = startingIDs.remove(item.id) != nil
            guard let ctx else { return }
            guard stillWanted else {
                Self.teardown(ctx)
                return
            }

            activePlaybacks[item.id] = ctx
            playingIDs.insert(item.id)
            if let unit = ctx.speakerUnit { AudioOutputUnitStart(unit) }
            if let unit = ctx.loopbackUnit { AudioOutputUnitStart(unit) }
            sbLogger.info("Playing: \(item.name) (loopback: \(ctx.loopbackUnit != nil))")
            pollForCompletion(id: item.id)
        }
    }

    func stop(id: UUID) {
        startingIDs.remove(id)
        guard let ctx = activePlaybacks.removeValue(forKey: id) else { return }
        Self.teardown(ctx)
        playingIDs.remove(id)
        updateMeter()
    }

    func stopAll() {
        startingIDs.removeAll()
        for id in Array(activePlaybacks.keys) {
            stop(id: id)
        }
    }

    // MARK: - Internal playback

    private func pollForCompletion(id: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.0 / 30.0))
            guard let self, let ctx = activePlaybacks[id] else { return }
            if ctx.done {
                stop(id: id)
            } else {
                updateMeter()
                pollForCompletion(id: id)
            }
        }
    }

    /// Stops both units and drops the render states they retained.
    private static func teardown(_ ctx: PlaybackContext) {
        for (unit, state) in [(ctx.speakerUnit, ctx.speakerState), (ctx.loopbackUnit, ctx.loopbackState)] {
            if let unit {
                AudioOutputUnitStop(unit)
                AudioUnitUninitialize(unit)
                AudioComponentInstanceDispose(unit)
            }
            if let state {
                Unmanaged.passUnretained(state).release()
            }
        }
    }

    /// Update the published meter level from active playbacks
    private func updateMeter() {
        var maxLevel: Float = 0
        for (_, ctx) in activePlaybacks {
            if ctx.meterLevel > maxLevel { maxLevel = ctx.meterLevel }
        }
        meterLevel = maxLevel
    }
}

// MARK: - Engine (decode + unit setup)

/// Off-main half of the soundboard: decodes files and builds stopped output units.
private actor SoundboardEngine {
    typealias DecodedBuffer = SoundboardPlayer.DecodedBuffer
    typealias RenderState = SoundboardPlayer.RenderState
    typealias PlaybackContext = SoundboardPlayer.PlaybackContext

    /// Decoded files keyed by bookmark; buffers stay alive for the app's lifetime.
    private var decodedCache: [Data: DecodedBuffer] = [:]

    /// Returns a context with initialized, not-yet-started units, or nil if the speaker unit fails.
    func prepare(item: SoundboardItem, globalVolume: Float) -> PlaybackContext? {
        guard let decoded = getOrDecodeBuffer(item: item) else {
            sbLogger.error("Failed to decode audio for \(item.name)")
            return nil
        }

        let ctx = PlaybackContext(itemID: item.id)

        // Speaker state + unit (so user hears the sound)
        let spkState = RenderState(buffer: decoded, volume: item.volume, globalVolume: globalVolume)
        guard let speakerUnit = createOutputUnit(state: spkState, deviceID: nil, decoded: decoded) else {
            sbLogger.error("Failed to create speaker output unit")
            return nil
        }
        ctx.speakerUnit = speakerUnit
        ctx.speakerState = spkState

        // Loopback state + unit (so Discord/Zoom hears it) — independent read position
        if let loopbackDeviceID = findDeviceByUID("LoopbackerDevice_UID") {
            let lbState = RenderState(buffer: decoded, volume: item.volume, globalVolume: globalVolume)
            if let lbUnit = createOutputUnit(state: lbState, deviceID: loopbackDeviceID, decoded: decoded) {
                ctx.loopbackUnit = lbUnit
                ctx.loopbackState = lbState
            } else {
                sbLogger.warning("Failed to create loopback unit — sound won't appear in Discord/Zoom")
            }
        } else {
            sbLogger.warning("Loopbacker virtual device not found — sound plays on speakers only")
        }

        return ctx
    }

    /// Helper: create an AudioUnit with a render callback, optionally targeting a specific device
    private func createOutputUnit(state: RenderState, deviceID: AudioObjectID?, decoded: DecodedBuffer) -> AudioComponentInstance? {
        let subType = deviceID != nil ? kAudioUnitSubType_HALOutput : kAudioUnitSubType_DefaultOutput
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: subType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else { return nil }

        var audioUnit: AudioComponentInstance?
        var status = AudioComponentInstanceNew(component, &audioUnit)
        guard status == noErr, let unit = audioUnit else { return nil }

        // Target specific device if provided
        if var devID = deviceID {
            status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &devID, UInt32(MemoryLayout<AudioObjectID>.size))
            guard status == noErr else { AudioComponentInstanceDispose(unit); return nil }
        }

        // Format
        var fmt = AudioStreamBasicDescription(
            mSampleRate: decoded.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: decoded.channelCount * 4, mFramesPerPacket: 1,
            mBytesPerFrame: decoded.channelCount * 4, mChannelsPerFrame: decoded.channelCount,
            mBitsPerChannel: 32, mReserved: 0
        )
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input, 0,
                                      &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { AudioComponentInstanceDispose(unit); return nil }

        // Render callback — each unit gets its own RenderState
        let contextPtr = Unmanaged.passRetained(state).toOpaque()
        var cb = AURenderCallbackStruct(inputProc: soundboardRenderCallback, inputProcRefCon: contextPtr)
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                      kAudioUnitScope_Input, 0,
                                      &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else {
            Unmanaged<RenderState>.fromOpaque(contextPtr).release()
            AudioComponentInstanceDispose(unit)
            return nil
        }

        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            Unmanaged<RenderState>.fromOpaque(contextPtr).release()
            AudioComponentInstanceDispose(unit)
            return nil
        }

        return unit
    }

    // MARK: - Audio file decoding

    private func getOrDecodeBuffer(item: SoundboardItem) -> DecodedBuffer? {
        // Check cache
        if let cached = decodedCache[item.fileBookmark] { return cached }

        // Resolve URL from bookmark
        guard let url = item.resolveURL() else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let audioFile = try? AVAudioFile(forReading: url) else { return nil }

        let srcFormat = audioFile.processingFormat
        let frameCount = UInt32(audioFile.length)
        guard frameCount > 0 else { return nil }

        // Always decode to 48kHz stereo float32 to match the Loopbacker virtual device
        let targetSampleRate: Double = 48000.0
        let channelCount: UInt32 = 2
        // Estimate output frame count after resampling
        let resampledFrameCount = UInt32(Double(frameCount) * targetSampleRate / srcFormat.sampleRate) + 256
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: true
        ) else { return nil }

        // Read the entire file into a non-interleaved buffer (AVAudioFile's native output)
        let readFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: srcFormat.sampleRate,
            channels: AVAudioChannelCount(srcFormat.channelCount),
            interleaved: false
        )!
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: frameCount) else { return nil }
        do {
            try audioFile.read(into: srcBuffer)
        } catch {
            sbLogger.error("Failed to read audio file: \(error)")
            return nil
        }
        sbLogger.info("Decoded \(srcBuffer.frameLength) frames at \(srcFormat.sampleRate)Hz, \(srcFormat.channelCount)ch")
        print("[Soundboard] Decoded \(srcBuffer.frameLength) frames at \(srcFormat.sampleRate)Hz")

        // Convert to interleaved stereo float32 at 48kHz
        guard let converter = AVAudioConverter(from: readFormat, to: targetFormat) else {
            sbLogger.error("Failed to create audio converter")
            return nil
        }
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: resampledFrameCount) else { return nil }

        // Use the simple block-based conversion with proper data supply
        var inputConsumed = false
        var convError: NSError?
        converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return srcBuffer
        }

        if let err = convError {
            sbLogger.error("Conversion error: \(err)")
            return nil
        }

        let actualFrames = outBuffer.frameLength
        guard actualFrames > 0 else {
            sbLogger.error("Conversion produced 0 frames")
            return nil
        }
        sbLogger.info("Converted to \(actualFrames) frames at 48kHz stereo")
        print("[Soundboard] Converted to \(actualFrames) frames at 48kHz stereo")

        let totalSamples = Int(actualFrames * channelCount)
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: totalSamples)

        // Copy to interleaved buffer
        if let floatData = outBuffer.floatChannelData {
            if targetFormat.isInterleaved {
                memcpy(samples, floatData[0], totalSamples * MemoryLayout<Float>.size)
            } else {
                // Interleave from separate channel buffers
                let srcChannels = Int(min(channelCount, UInt32(outBuffer.format.channelCount)))
                for frame in 0..<Int(actualFrames) {
                    for ch in 0..<Int(channelCount) {
                        let srcCh = min(ch, srcChannels - 1)  // mono -> duplicate to both channels
                        samples[frame * Int(channelCount) + ch] = floatData[srcCh][frame]
                    }
                }
            }
        }

        let decoded = DecodedBuffer(
            samples: samples,
            frameCount: actualFrames,
            channelCount: channelCount,
            sampleRate: targetSampleRate
        )

        decodedCache[item.fileBookmark] = decoded
        return decoded
    }

    // MARK: - Device lookup (same as AudioRouter)

    private func findDeviceByUID(_ uid: String) -> AudioObjectID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else { return nil }

        for deviceID in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfUID: Unmanaged<CFString>? = nil
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let s = withUnsafeMutablePointer(to: &cfUID) { ptr in
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
            }
            guard s == noErr, let cf = cfUID else { continue }
            if (cf.takeRetainedValue() as String) == uid { return deviceID }
        }
        return nil
    }
}

// MARK: - Render callback (C function)

private func soundboardRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let state = Unmanaged<SoundboardPlayer.RenderState>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let bufferList = ioData else { return noErr }

    let abl = UnsafeMutableAudioBufferListPointer(bufferList)
    guard abl.count > 0, let outBuf = abl[0].mData?.assumingMemoryBound(to: Float.self) else {
        return noErr
    }

    let chCount = Int(state.buffer.channelCount)
    let remaining = state.buffer.frameCount - state.readPosition
    let toPlay = min(inNumberFrames, remaining)
    let vol = state.volume * state.globalVolume

    let srcOffset = Int(state.readPosition) * chCount
    var peak: Float = 0
    for i in 0..<Int(toPlay) {
        for ch in 0..<chCount {
            let sample = state.buffer.samples[srcOffset + i * chCount + ch] * vol
            outBuf[i * chCount + ch] = sample
            let s = sample < 0 ? -sample : sample
            if s > peak { peak = s }
        }
    }
    state.meterLevel = peak

    if toPlay < inNumberFrames {
        let offset = Int(toPlay) * chCount
        let rem = Int(inNumberFrames - toPlay) * chCount
        for j in 0..<rem { outBuf[offset + j] = 0.0 }
        state.done = true
    }

    state.readPosition += toPlay
    return noErr
}
