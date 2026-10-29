#!/usr/bin/swift
// tone.swift -- plays a quiet 440 Hz tone to a named CoreAudio output device, with level
// swinging -40..-20 dBFS at 1.5 Hz so meters (and any AGC/limiter) keep moving instead of
// sitting at a fixed level. Useful for exercising routes/meters without real program audio.
//
// Usage:
//   scripts/bench/tone.swift <output device name> [seconds]
//
// <output device name> matches (case-insensitively, substring) against the device's
// kAudioObjectPropertyName; the first match is used. Defaults to 5 seconds if unspecified.
import AudioToolbox
import CoreAudio
import Foundation

let args = CommandLine.arguments.dropFirst()
guard let deviceName = args.first else {
    FileHandle.standardError.write("usage: tone.swift <output device name> [seconds]\n".data(using: .utf8)!)
    exit(1)
}
let seconds = args.count > 1 ? Double(Array(args)[1]) ?? 5 : 5

let sampleRate = 48_000.0
let channels: UInt32 = 2
let toneHz = 440.0
let swingHz = 1.5 // level LFO rate
let minDb = -40.0, maxDb = -20.0

func findDeviceUID(named name: String) -> String? {
    var size: UInt32 = 0
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
    let needle = name.lowercased()
    for id in ids {
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var nameRef: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &nameRef) == noErr,
              let cfName = nameRef?.takeRetainedValue() else { continue }
        guard (cfName as String).lowercased().contains(needle) else { continue }

        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uidRef: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uidRef) == noErr,
              let cfUID = uidRef?.takeRetainedValue() else { continue }
        return cfUID as String
    }
    return nil
}

guard let uid = findDeviceUID(named: deviceName) else {
    FileHandle.standardError.write("tone.swift: no output device matching \"\(deviceName)\"\n".data(using: .utf8)!)
    exit(1)
}
print("tone.swift: routing to device UID \(uid)")

var format = AudioStreamBasicDescription(
    mSampleRate: sampleRate,
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
    mBytesPerPacket: 4 * channels,
    mFramesPerPacket: 1,
    mBytesPerFrame: 4 * channels,
    mChannelsPerFrame: channels,
    mBitsPerChannel: 32,
    mReserved: 0)

let framesPerBuffer = 2048
var sampleIndex: Double = 0
var queue: AudioQueueRef?

let callback: AudioQueueOutputCallback = { userData, inQueue, inBuffer in
    let ptr = inBuffer.pointee.mAudioData.assumingMemoryBound(to: Float32.self)
    for f in 0..<framesPerBuffer {
        let t = sampleIndex / sampleRate
        let swing = 0.5 * (1 + sin(2 * .pi * swingHz * t)) // 0..1
        let db = minDb + swing * (maxDb - minDb)
        let amp = Float(pow(10.0, db / 20.0))
        let s = amp * Float(sin(2 * .pi * toneHz * t))
        ptr[f * Int(channels)] = s
        ptr[f * Int(channels) + 1] = s
        sampleIndex += 1
    }
    inBuffer.pointee.mAudioDataByteSize = UInt32(framesPerBuffer) * format.mBytesPerFrame
    AudioQueueEnqueueBuffer(inQueue, inBuffer, 0, nil)
}

var status = AudioQueueNewOutput(&format, callback, nil, nil, nil, 0, &queue)
guard status == noErr, let q = queue else {
    FileHandle.standardError.write("AudioQueueNewOutput failed: \(status)\n".data(using: .utf8)!)
    exit(1)
}

var deviceUID = uid as CFString
status = withUnsafeMutablePointer(to: &deviceUID) {
    AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, $0, UInt32(MemoryLayout<CFString>.size))
}
guard status == noErr else {
    FileHandle.standardError.write("AudioQueueSetProperty(CurrentDevice) failed: \(status)\n".data(using: .utf8)!)
    exit(1)
}

var buffers = [AudioQueueBufferRef?](repeating: nil, count: 3)
for i in 0..<buffers.count {
    AudioQueueAllocateBuffer(q, UInt32(framesPerBuffer) * format.mBytesPerFrame, &buffers[i])
    if let buf = buffers[i] {
        callback(nil, q, buf)
    }
}

status = AudioQueueStart(q, nil)
guard status == noErr else {
    FileHandle.standardError.write("AudioQueueStart failed: \(status)\n".data(using: .utf8)!)
    exit(1)
}

print(String(format: "tone.swift: playing %.0f Hz at %.0f..%.0f dBFS (%.1f Hz swing) for %.1f s",
             toneHz, minDb, maxDb, swingHz, seconds))
Thread.sleep(forTimeInterval: seconds)

AudioQueueStop(q, true)
AudioQueueDispose(q, true)
