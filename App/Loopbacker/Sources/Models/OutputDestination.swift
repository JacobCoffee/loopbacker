import Foundation

/// Represents a mapping from a Loopbacker virtual device to a physical audio output.
struct OutputDestination: Identifiable, Equatable, Codable {
    let id: UUID
    var virtualDeviceUID: String
    var virtualDeviceName: String
    var physicalOutputUID: String
    var physicalOutputName: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        virtualDeviceUID: String,
        virtualDeviceName: String,
        physicalOutputUID: String = "",
        physicalOutputName: String = "None",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.virtualDeviceUID = virtualDeviceUID
        self.virtualDeviceName = virtualDeviceName
        self.physicalOutputUID = physicalOutputUID
        self.physicalOutputName = physicalOutputName
        self.isEnabled = isEnabled
    }
}
