import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import os.log

private let sbLogger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "SoundboardPlayer")

/// Plays audio files through the Loopbacker virtual device so they appear
/// in Discord, Zoom, OBS, etc. Each sound gets its own AUHAL output unit;
/// CoreAudio handles mixing multiple simultaneous sounds on the device side.
class SoundboardPlayer: ObservableObject {
    @Published var playingIDs: Set<UUID> = []
    @Published var meterLevel: Float = 0.0  // global output level for UI

    /// Global volume multiplier (0...1)
    var globalVolume: Float = 1.0

    private var activePlaybacks: [UUID: PlaybackContext] = [:]
    private var decodedCache: [Data: DecodedBuffer] = [:]  // keyed by bookmark data
    private let queue = DispatchQueue(label: "com.jacobcoffee.loopbacker.soundboard", qos: .userInteractive)

    // MARK: - Decoded audio buffer

    fileprivate struct DecodedBuffer {
        let samples: UnsafeMutablePointer<Float>  // interleaved stereo float32
        let frameCount: UInt32
        let channelCount: UInt32
        let sampleRate: Float64
    }

    // MARK: - Per-sound playback context

    fileprivate class PlaybackContext {
        var speakerUnit: AudioComponentInstance?   // plays through speakers (monitor)
        var loopbackUnit: AudioComponentInstance?  // plays through virtual device (Discord/Zoom)
        var buffer: DecodedBuffer
        var readPosition: UInt32 = 0
        var volume: Float = 1.0
        var globalVolume: Float = 1.0
        var done: Bool = false
        var meterLevel: Float = 0.0  // peak level for UI meter
        let itemID: UUID

        init(buffer: DecodedBuffer, itemID: UUID, volume: Float, globalVolume: Float) {
            self.buffer = buffer
            self.itemID = itemID
            self.volume = volume
            self.globalVolume = globalVolume
        }
    }

    // MARK: - Public API

    func play(item: SoundboardItem) {
        // Toggle: if already playing, stop it
        if activePlaybacks[item.id] != nil {
            stop(id: item.id)
            return
        }

        queue.async { [weak self] in
            self?.startPlayback(item: item)
        }
    }

    func stop(id: UUID) {
        queue.async { [weak self] in
            self?.stopPlayback(id: id)
        }
    }

    func stopAll() {
        queue.async { [weak self] in
            guard let self else { return }
            for id in Array(self.activePlaybacks.keys) {
                self.stopPlayback(id: id)
            }
        }
    }

    // MARK: - Internal playback

    /// Helper: create an AudioUnit with a render callback, optionally targeting a specific device
    private func createOutputUnit(ctx: PlaybackContext, deviceID: AudioObjectID?, decoded: DecodedBuffer) -> AudioComponentInstance? {
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

        // Render callback (shared context - the speaker unit drives playback position)
        let contextPtr = Unmanaged.passRetained(ctx).toOpaque()
        var cb = AURenderCallbackStruct(inputProc: soundboardRenderCallback, inputProcRefCon: contextPtr)
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                      kAudioUnitScope_Input, 0,
                                      &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else {
            Unmanaged<PlaybackContext>.fromOpaque(contextPtr).release()
            AudioComponentInstanceDispose(unit)
            return nil
        }

        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            Unmanaged<PlaybackContext>.fromOpaque(contextPtr).release()
            AudioComponentInstanceDispose(unit)
            return nil
        }

        return unit
    }

    private func startPlayback(item: SoundboardItem) {
        guard let decoded = getOrDecodeBuffer(item: item) else {
            sbLogger.error("Failed to decode audio for \(item.name)")
            return
        }

        let ctx = PlaybackContext(
            buffer: decoded, itemID: item.id,
            volume: item.volume, globalVolume: globalVolume
        )

        // Speaker unit (so user hears the sound)
        guard let speakerUnit = createOutputUnit(ctx: ctx, deviceID: nil, decoded: decoded) else {
            sbLogger.error("Failed to create speaker output unit")
            return
        }
        ctx.speakerUnit = speakerUnit

        // Loopback unit (so Discord/Zoom hears it)
        if let loopbackDeviceID = findDeviceByUID("LoopbackerDevice_UID") {
            if let lbUnit = createOutputUnit(ctx: ctx, deviceID: loopbackDeviceID, decoded: decoded) {
                ctx.loopbackUnit = lbUnit
            }
        }

        activePlaybacks[item.id] = ctx

        DispatchQueue.main.async { [weak self] in
            self?.playingIDs.insert(item.id)
        }

        // Start speaker (drives the read position)
        AudioOutputUnitStart(speakerUnit)
        // Start loopback if available
        if let lb = ctx.loopbackUnit { AudioOutputUnitStart(lb) }

        sbLogger.info("Playing: \(item.name)")
        pollForCompletion(id: item.id)
    }

    private func pollForCompletion(id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0) { [weak self] in
            guard let self else { return }
            guard let ctx = self.activePlaybacks[id] else { return }
            if ctx.done {
                self.stop(id: id)
            } else {
                self.updateMeter()
                self.pollForCompletion(id: id)
            }
        }
    }

    private func stopPlayback(id: UUID) {
        guard let ctx = activePlaybacks.removeValue(forKey: id) else { return }

        // Tear down speaker unit
        if let unit = ctx.speakerUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            Unmanaged.passUnretained(ctx).release()  // balance passRetained from createOutputUnit
        }

        // Tear down loopback unit
        if let unit = ctx.loopbackUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            Unmanaged.passUnretained(ctx).release()  // balance passRetained
        }

        DispatchQueue.main.async { [weak self] in
            self?.playingIDs.remove(id)
            self?.updateMeter()
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

        // Target format: stereo float32 at source sample rate
        let channelCount: UInt32 = 2
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: srcFormat.sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: true
        ) else { return nil }

        // Read into a buffer
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else { return nil }
        do {
            try audioFile.read(into: srcBuffer)
        } catch {
            sbLogger.error("Failed to read audio file: \(error)")
            return nil
        }

        // Convert to interleaved stereo float32
        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else { return nil }
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return nil }

        var convError: NSError?
        converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            outStatus.pointee = .haveData
            return srcBuffer
        }

        if let err = convError {
            sbLogger.error("Conversion error: \(err)")
            return nil
        }

        let actualFrames = outBuffer.frameLength
        let totalSamples = Int(actualFrames * channelCount)
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: totalSamples)

        // Copy interleaved data
        if let floatData = outBuffer.floatChannelData {
            if targetFormat.isInterleaved {
                memcpy(samples, floatData[0], totalSamples * MemoryLayout<Float>.size)
            } else {
                // De-interleave: copy channel by channel
                for frame in 0..<Int(actualFrames) {
                    for ch in 0..<Int(channelCount) {
                        samples[frame * Int(channelCount) + ch] = floatData[ch][frame]
                    }
                }
            }
        }

        let decoded = DecodedBuffer(
            samples: samples,
            frameCount: actualFrames,
            channelCount: channelCount,
            sampleRate: srcFormat.sampleRate
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
    let ctx = Unmanaged<SoundboardPlayer.PlaybackContext>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let bufferList = ioData else { return noErr }

    let abl = UnsafeMutableAudioBufferListPointer(bufferList)
    guard abl.count > 0, let outBuf = abl[0].mData?.assumingMemoryBound(to: Float.self) else {
        return noErr
    }

    let chCount = Int(ctx.buffer.channelCount)
    let remaining = ctx.buffer.frameCount - ctx.readPosition
    let toPlay = min(inNumberFrames, remaining)
    let vol = ctx.volume * ctx.globalVolume

    // Copy decoded samples to output with volume + track peak for meter
    let srcOffset = Int(ctx.readPosition) * chCount
    var peak: Float = 0
    for i in 0..<Int(toPlay) {
        for ch in 0..<chCount {
            let sample = ctx.buffer.samples[srcOffset + i * chCount + ch] * vol
            outBuf[i * chCount + ch] = sample
            let abs = sample < 0 ? -sample : sample
            if abs > peak { peak = abs }
        }
    }
    ctx.meterLevel = peak

    // Zero-fill remainder if file ended
    if toPlay < inNumberFrames {
        let offset = Int(toPlay) * chCount
        let remaining = Int(inNumberFrames - toPlay) * chCount
        for j in 0..<remaining { outBuf[offset + j] = 0.0 }
        ctx.done = true
    }

    ctx.readPosition += toPlay
    return noErr
}
