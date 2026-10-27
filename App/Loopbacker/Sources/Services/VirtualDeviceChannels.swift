import CoreAudio
import Foundation

/// Channel count of a Loopbacker virtual device, read and written through the driver's
/// `'lbch'` custom property (CFNumber, even values 2...16). Both streams of a device share
/// the count, and the driver persists it across coreaudiod restarts.
enum VirtualDeviceChannels {
    /// `kLoopbackerDevicePropertyChannelCount` in Driver/src/LoopbackerTypes.h.
    static let selector: AudioObjectPropertySelector = 0x6C62_6368 // 'lbch'
    /// The virtual mic every source routes into.
    static let micUID = "LoopbackerDevice_UID"
    static let supportedCounts: [Int] = Array(stride(from: 2, through: 16, by: 2))
    static let maxCount = 16

    /// Smallest supported count that fits `channels` (rounded up to a pair, clamped to 2...16).
    static func deviceCount(forChannels channels: Int) -> Int {
        min(maxCount, max(2, channels + channels % 2))
    }

    /// Current count, or nil when the device is missing or its driver predates the property.
    static func count(deviceUID: String) -> Int? {
        guard let deviceID = deviceID(forUID: deviceUID) else { return nil }
        var address = propertyAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let number = value?.takeRetainedValue() as? NSNumber else { return nil }
        return number.intValue
    }

    /// Ask the driver to reconfigure the device. The HAL applies it asynchronously; poll
    /// `count(deviceUID:)` or the stream configuration to see it land.
    @discardableResult
    static func setCount(_ count: Int, deviceUID: String) -> Bool {
        guard supportedCounts.contains(count), let deviceID = deviceID(forUID: deviceUID) else { return false }
        var address = propertyAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var value: CFPropertyList = NSNumber(value: Int32(count))
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                       UInt32(MemoryLayout<CFPropertyList>.size), $0)
        }
        return status == noErr
    }

    private static var propertyAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceID(forUID uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &deviceID)
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}
