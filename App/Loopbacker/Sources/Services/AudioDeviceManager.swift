import Foundation
import CoreAudio
import Combine

class AudioDeviceManager: ObservableObject {
    @Published var systemDevices: [SystemAudioDevice] = []
    @Published var loopbackerDevicePresent: Bool = false

    /// Set after init to auto-populate sources from real devices
    weak var routingState: RoutingState?

    private var propertyListenerBlock: AudioObjectPropertyListenerBlock?
    private var didPopulateInitial = false

    init() {
        // Synchronous on init -- populate immediately so data is ready for onAppear
        systemDevices = fetchDevices()
        loopbackerDevicePresent = systemDevices.contains { $0.uid.contains("Loopbacker") || $0.name.contains("Loopbacker") }
        installDeviceChangeListener()
    }

    /// Call once after routingState is available -- just stores the reference.
    /// Sources are added manually by the user via the + button.
    func populateInitialSources(into state: RoutingState) {
        guard !didPopulateInitial else { return }
        didPopulateInitial = true
        self.routingState = state
    }

    deinit {
        removeDeviceChangeListener()
    }

    // MARK: - Device enumeration via CoreAudio C API

    func enumerateDevices() {
        let devices = fetchDevices()
        DispatchQueue.main.async {
            self.systemDevices = devices
            self.loopbackerDevicePresent = devices.contains { $0.uid.contains("Loopbacker") || $0.name.contains("Loopbacker") }
        }
    }

    private func fetchDevices() -> [SystemAudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        var devices: [SystemAudioDevice] = []

        for deviceID in deviceIDs {
            guard let name = getDeviceName(deviceID) else { continue }
            let uid = getDeviceUID(deviceID) ?? ""
            let inputCount = getChannelCount(deviceID, scope: kAudioObjectPropertyScopeInput)
            let outputCount = getChannelCount(deviceID, scope: kAudioObjectPropertyScopeOutput)

            let device = SystemAudioDevice(
                id: deviceID,
                uid: uid,
                name: name,
                inputChannelCount: inputCount,
                outputChannelCount: outputCount,
                isInput: inputCount > 0,
                isOutput: outputCount > 0
            )
            devices.append(device)
        }

        return devices
    }

    // MARK: - Property helpers

    private func getStringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var result: Unmanaged<CFString>? = nil
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &result) { ptr in
            AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, ptr)
        }
        guard status == noErr, let cf = result else { return nil }
        // CoreAudio "Get" rule: caller does NOT own the CFString
        return cf.takeUnretainedValue() as String
    }

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        getStringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
    }

    private func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        getStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private func getChannelCount(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return 0 }

        // Allocate enough raw memory for the variable-length AudioBufferList
        let rawPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawPointer.deallocate() }

        let bufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)

        status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferListPointer)
        guard status == noErr else { return 0 }

        var totalChannels: UInt32 = 0
        let buffers = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        for buffer in buffers {
            totalChannels += buffer.mNumberChannels
        }
        return Int(totalChannels)
    }

    // MARK: - Device change monitoring

    private func installDeviceChangeListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.enumerateDevices()
        }
        self.propertyListenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
    }

    private func removeDeviceChangeListener() {
        guard let block = propertyListenerBlock else { return }
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
    }

    // MARK: - Output device enumeration

    /// Returns system devices that have output channels (for output routing picker).
    /// Excludes Loopbacker virtual devices since those are the sources, not destinations.
    var outputDevices: [SystemAudioDevice] {
        systemDevices.filter { $0.isOutput && !$0.uid.contains("Loopbacker") && !$0.name.contains("Loopbacker") }
    }

    // MARK: - Create AudioSource from a system device

    func createSource(from device: SystemAudioDevice) -> AudioSource {
        let channelCount = max(device.inputChannelCount, 1)
        let channels: [AudioChannel] = (1...channelCount).map { i in
            let label: String
            if channelCount == 2 {
                label = i == 1 ? "\(i) (L)" : "\(i) (R)"
            } else if channelCount > 2 {
                // For multi-channel devices, label L/R on first two
                switch i {
                case 1: label = "\(i) (L)"
                case 2: label = "\(i) (R)"
                default: label = "\(i)"
                }
            } else {
                label = "\(i)"
            }
            return AudioChannel(id: i, label: label)
        }

        let icon: String
        if device.isInput && !device.isOutput {
            icon = "mic.fill"
        } else if device.isOutput && !device.isInput {
            icon = "speaker.wave.2.fill"
        } else {
            icon = "hifispeaker.fill"
        }

        return AudioSource(
            name: device.name,
            icon: icon,
            channels: channels,
            isEnabled: true,
            deviceUID: device.uid
        )
    }
}
