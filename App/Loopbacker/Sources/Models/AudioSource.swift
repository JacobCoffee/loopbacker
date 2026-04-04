import Foundation
import CoreAudio

struct AudioChannel: Identifiable, Equatable, Codable {
    let id: Int
    let label: String
    var volume: Float
    var isActive: Bool
    var meterLevel: Float

    init(id: Int, label: String, volume: Float = 1.0, isActive: Bool = true, meterLevel: Float = 0.0) {
        self.id = id
        self.label = label
        self.volume = volume
        self.isActive = isActive
        self.meterLevel = meterLevel
    }

    // Exclude meterLevel from persistence (it's transient runtime data)
    enum CodingKeys: String, CodingKey {
        case id, label, volume, isActive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        volume = try container.decode(Float.self, forKey: .volume)
        isActive = try container.decode(Bool.self, forKey: .isActive)
        meterLevel = 0.0
    }
}

struct AudioSource: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var icon: String
    var channels: [AudioChannel]
    var isEnabled: Bool
    var isPassThrough: Bool
    var isMuted: Bool
    /// The CoreAudio device UID for this source (used by AudioRouter)
    var deviceUID: String

    init(
        id: UUID = UUID(),
        name: String,
        icon: String = "mic.fill",
        channels: [AudioChannel],
        isEnabled: Bool = true,
        isPassThrough: Bool = false,
        isMuted: Bool = false,
        deviceUID: String = ""
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.channels = channels
        self.isEnabled = isEnabled
        self.isPassThrough = isPassThrough
        self.isMuted = isMuted
        self.deviceUID = deviceUID
    }

    // Backward-compatible decoding: isMuted may not exist in old configs
    enum CodingKeys: String, CodingKey {
        case id, name, icon, channels, isEnabled, isPassThrough, isMuted, deviceUID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(String.self, forKey: .icon)
        channels = try container.decode([AudioChannel].self, forKey: .channels)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        isPassThrough = try container.decode(Bool.self, forKey: .isPassThrough)
        isMuted = (try? container.decode(Bool.self, forKey: .isMuted)) ?? false
        deviceUID = try container.decode(String.self, forKey: .deviceUID)
    }
}

// MARK: - Discovered system audio device (from CoreAudio enumeration)

struct SystemAudioDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let inputChannelCount: Int
    let outputChannelCount: Int
    let isInput: Bool
    let isOutput: Bool
}

// AudioObjectID comes from CoreAudio
