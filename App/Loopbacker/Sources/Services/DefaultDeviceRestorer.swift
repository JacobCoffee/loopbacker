import Foundation
import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "DefaultDeviceRestorer")

/// Records the system's default input/output devices on launch and restores them
/// on quit if they are still set to a Loopbacker virtual device.
/// This prevents the user from being stuck on a non-functional device after quitting.
final class DefaultDeviceRestorer {
    static let shared = DefaultDeviceRestorer()

    private var savedDefaultInput: AudioDeviceID?
    private var savedDefaultOutput: AudioDeviceID?

    private init() {}

    // MARK: - Public API

    /// Call once at app launch to snapshot the current defaults.
    func saveDefaults() {
        let currentInput = getDefaultDevice(scope: kAudioHardwarePropertyDefaultInputDevice)
        let currentOutput = getDefaultDevice(scope: kAudioHardwarePropertyDefaultOutputDevice)

        // Only save if they're NOT already Loopbacker devices (otherwise there's nothing to restore to)
        if let id = currentInput, !isLoopbackerDevice(id) {
            savedDefaultInput = id
            logger.info("Saved default input: \(self.deviceName(id) ?? "?") (\(id))")
        }
        if let id = currentOutput, !isLoopbackerDevice(id) {
            savedDefaultOutput = id
            logger.info("Saved default output: \(self.deviceName(id) ?? "?") (\(id))")
        }
    }

    /// Call on app quit. Restores defaults only if they are currently set to a Loopbacker device.
    func restoreDefaultsIfNeeded() {
        if let savedInput = savedDefaultInput {
            let currentInput = getDefaultDevice(scope: kAudioHardwarePropertyDefaultInputDevice)
            if let current = currentInput, isLoopbackerDevice(current) {
                let name = deviceName(savedInput) ?? "unknown"
                logger.info("Restoring default input to \(name) (\(savedInput))")
                setDefaultDevice(savedInput, scope: kAudioHardwarePropertyDefaultInputDevice)
            }
        }

        if let savedOutput = savedDefaultOutput {
            let currentOutput = getDefaultDevice(scope: kAudioHardwarePropertyDefaultOutputDevice)
            if let current = currentOutput, isLoopbackerDevice(current) {
                let name = deviceName(savedOutput) ?? "unknown"
                logger.info("Restoring default output to \(name) (\(savedOutput))")
                setDefaultDevice(savedOutput, scope: kAudioHardwarePropertyDefaultOutputDevice)
            }
        }
    }

    // MARK: - CoreAudio helpers

    private func getDefaultDevice(scope: AudioObjectPropertySelector) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: scope,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private func setDefaultDevice(_ deviceID: AudioDeviceID, scope: AudioObjectPropertySelector) {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: scope,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id
        )
        if status != noErr {
            logger.error("Failed to set default device \(deviceID), status: \(status)")
        }
    }

    private func isLoopbackerDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard let uid = deviceUID(deviceID) else { return false }
        return uid.contains("Loopbacker")
    }

    private func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var result: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &result) { ptr in
            AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf = result else { return nil }
        return cf.takeUnretainedValue() as String
    }

    private func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var result: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &result) { ptr in
            AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf = result else { return nil }
        return cf.takeUnretainedValue() as String
    }
}
