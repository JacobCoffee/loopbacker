import Foundation

/// Represents a mapping from a Loopbacker virtual device to a physical audio output.
struct OutputDestination: Identifiable, Equatable, Codable {
    let id: UUID
    var virtualDeviceUID: String
    var virtualDeviceName: String
    var physicalOutputUID: String
    var physicalOutputName: String
    var isEnabled: Bool
    /// Channels the virtual device exposes to apps (even, 2...16).
    var channelCount: Int
    /// First channel (1-based) of the pair played to the physical output.
    var monitorChannel: Int

    init(
        id: UUID = UUID(),
        virtualDeviceUID: String,
        virtualDeviceName: String,
        physicalOutputUID: String = "",
        physicalOutputName: String = "None",
        isEnabled: Bool = true,
        channelCount: Int = 2,
        monitorChannel: Int = 1
    ) {
        self.id = id
        self.virtualDeviceUID = virtualDeviceUID
        self.virtualDeviceName = virtualDeviceName
        self.physicalOutputUID = physicalOutputUID
        self.physicalOutputName = physicalOutputName
        self.isEnabled = isEnabled
        self.channelCount = channelCount
        self.monitorChannel = monitorChannel
    }

    // Configs saved before multichannel support have no channel fields.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        virtualDeviceUID = try container.decode(String.self, forKey: .virtualDeviceUID)
        virtualDeviceName = try container.decode(String.self, forKey: .virtualDeviceName)
        physicalOutputUID = try container.decode(String.self, forKey: .physicalOutputUID)
        physicalOutputName = try container.decode(String.self, forKey: .physicalOutputName)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        channelCount = try container.decodeIfPresent(Int.self, forKey: .channelCount) ?? 2
        monitorChannel = try container.decodeIfPresent(Int.self, forKey: .monitorChannel) ?? 1
    }
}
