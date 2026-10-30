import Foundation
import CoreAudio

struct AudioChannel: Identifiable, Equatable, Codable {
    let id: Int
    let label: String
    var volume: Float
    var isActive: Bool

    init(id: Int, label: String, volume: Float = 1.0, isActive: Bool = true) {
        self.id = id
        self.label = label
        self.volume = volume
        self.isActive = isActive
    }
}

struct AudioSource: Identifiable, Equatable, Codable {
    /// Distinguishes hardware device sources from app audio capture sources
    enum SourceType: String, Codable {
        case device      // CoreAudio hardware device
        case appCapture  // ScreenCaptureKit app audio
    }

    let id: UUID
    var name: String
    var icon: String
    var channels: [AudioChannel]
    var isEnabled: Bool
    var isPassThrough: Bool
    var isMuted: Bool
    /// The CoreAudio device UID for this source, or "app:<bundleID>" for app capture sources
    var deviceUID: String
    /// Physical output device UID for monitoring (hear yourself through speakers)
    var monitorOutputUID: String
    var monitorOutputName: String
    /// Source type: hardware device or app audio capture
    var sourceType: SourceType
    /// Bundle identifier for app capture sources (empty for device sources)
    var appBundleID: String
    /// Noise suppression for this device's voice routes (virtual mic and monitor), when it's
    /// switched on globally. App captures are never denoised.
    var noiseSuppression: Bool
    /// The monitor (hearing yourself) is denoised too. Off, it skips suppression and its delay;
    /// the virtual mic stays denoised.
    var denoiseMonitor: Bool
    /// Echo cancellation for this device's voice routes, when it's switched on globally.
    /// Mirrors `noiseSuppression`'s per-source opt-out. App captures are never run through it.
    var echoCancellation: Bool
    /// Ordered device preferences for this source (most-preferred first). When the currently
    /// bound device disappears, the source rebinds to the next present entry; when a
    /// higher-preference device reappears, it switches back. Empty means "no opinion" — falls
    /// back to matching a device with the same name.
    var fallbackDevices: [DeviceFallbackEntry]

    init(
        id: UUID = UUID(),
        name: String,
        icon: String = "mic.fill",
        channels: [AudioChannel],
        isEnabled: Bool = true,
        isPassThrough: Bool = false,
        isMuted: Bool = false,
        deviceUID: String = "",
        monitorOutputUID: String = "",
        monitorOutputName: String = "",
        sourceType: SourceType = .device,
        appBundleID: String = "",
        noiseSuppression: Bool = true,
        denoiseMonitor: Bool = true,
        echoCancellation: Bool = true,
        fallbackDevices: [DeviceFallbackEntry] = []
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.channels = channels
        self.isEnabled = isEnabled
        self.isPassThrough = isPassThrough
        self.isMuted = isMuted
        self.deviceUID = deviceUID
        self.monitorOutputUID = monitorOutputUID
        self.monitorOutputName = monitorOutputName
        self.sourceType = sourceType
        self.appBundleID = appBundleID
        self.noiseSuppression = noiseSuppression
        self.denoiseMonitor = denoiseMonitor
        self.echoCancellation = echoCancellation
        self.fallbackDevices = fallbackDevices
    }

    var isAppCapture: Bool { sourceType == .appCapture }

    /// Adds `entry` to `fallbackDevices`, seeding the list with the device this source is
    /// *currently* bound to first if the list was empty. Without that seed, the first fallback
    /// the user adds would silently outrank the device the source is actually using today --
    /// the next enumeration could switch away from a working interface it was never told about,
    /// and never switch back since the working device was never in the preference list at all.
    mutating func addFallbackDevice(_ entry: DeviceFallbackEntry) {
        if fallbackDevices.isEmpty && !deviceUID.isEmpty {
            fallbackDevices.append(DeviceFallbackEntry(uid: deviceUID, name: name))
        }
        guard !fallbackDevices.contains(where: { $0.uid == entry.uid }) else { return }
        fallbackDevices.append(entry)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, icon, channels, isEnabled, isPassThrough, isMuted, deviceUID
        case monitorOutputUID, monitorOutputName, sourceType, appBundleID, noiseSuppression, denoiseMonitor
        case echoCancellation
        case fallbackDevices
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
        monitorOutputUID = (try? container.decode(String.self, forKey: .monitorOutputUID)) ?? ""
        monitorOutputName = (try? container.decode(String.self, forKey: .monitorOutputName)) ?? ""
        sourceType = (try? container.decode(SourceType.self, forKey: .sourceType)) ?? .device
        appBundleID = (try? container.decode(String.self, forKey: .appBundleID)) ?? ""
        noiseSuppression = (try? container.decode(Bool.self, forKey: .noiseSuppression)) ?? true
        denoiseMonitor = (try? container.decode(Bool.self, forKey: .denoiseMonitor)) ?? true
        echoCancellation = (try? container.decode(Bool.self, forKey: .echoCancellation)) ?? true
        fallbackDevices = (try? container.decode([DeviceFallbackEntry].self, forKey: .fallbackDevices)) ?? []
    }

    /// Create an AudioSource from a captured app
    static func fromApp(_ app: CaptureApp) -> AudioSource {
        AudioSource(
            name: app.name,
            icon: "app.badge.fill",
            channels: [
                AudioChannel(id: 1, label: "1 (L)"),
                AudioChannel(id: 2, label: "2 (R)")
            ],
            isEnabled: true,
            deviceUID: "app:\(app.id)",
            sourceType: .appCapture,
            appBundleID: app.id
        )
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
