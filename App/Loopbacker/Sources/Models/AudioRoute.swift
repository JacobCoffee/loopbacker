import Foundation
import SwiftUI
import Combine

/// Which Loopbacker virtual mic a route feeds. Routes saved before Stream Mix existed decode
/// as `.virtualMic`.
enum RouteTarget: String, Codable, Hashable, CaseIterable, Sendable {
    case virtualMic
    case streamMix

    var deviceUID: String {
        switch self {
        case .virtualMic: return VirtualDeviceChannels.micUID
        case .streamMix: return VirtualDeviceChannels.streamUID
        }
    }
}

struct AudioRoute: Identifiable, Equatable, Codable {
    let id: UUID
    var sourceId: UUID
    var sourceChannelId: Int
    var targetId: RouteTarget
    var outputChannelId: Int

    init(id: UUID = UUID(), sourceId: UUID, sourceChannelId: Int, targetId: RouteTarget = .virtualMic,
         outputChannelId: Int) {
        self.id = id
        self.sourceId = sourceId
        self.sourceChannelId = sourceChannelId
        self.targetId = targetId
        self.outputChannelId = outputChannelId
    }

    // Backward-compatible decoding: routes saved before Stream Mix existed have no `targetId`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceId = try container.decode(UUID.self, forKey: .sourceId)
        sourceChannelId = try container.decode(Int.self, forKey: .sourceChannelId)
        outputChannelId = try container.decode(Int.self, forKey: .outputChannelId)
        targetId = (try? container.decode(RouteTarget.self, forKey: .targetId)) ?? .virtualMic
    }
}

// MARK: - Connector identity for cable routing

enum ConnectorEnd: Equatable, Hashable {
    case source(sourceId: UUID, channelId: Int)
    case output(target: RouteTarget, channelId: Int)

    func hash(into hasher: inout Hasher) {
        switch self {
        case .source(let sid, let ch):
            hasher.combine(0)
            hasher.combine(sid)
            hasher.combine(ch)
        case .output(let target, let ch):
            hasher.combine(1)
            hasher.combine(target)
            hasher.combine(ch)
        }
    }
}

// MARK: - Persistable routing configuration

struct RoutingConfig: Codable {
    var sources: [AudioSource]
    var outputChannels: [AudioChannel]
    var streamOutputChannels: [AudioChannel]
    var streamMixEnabled: Bool
    var routes: [AudioRoute]
    var outputDestinations: [OutputDestination]
    var effectsPreset: EffectsPreset
    var noiseSuppression: NoiseSuppressionSettings

    init(sources: [AudioSource], outputChannels: [AudioChannel], streamOutputChannels: [AudioChannel] = [],
         streamMixEnabled: Bool = false, routes: [AudioRoute],
         outputDestinations: [OutputDestination] = [], effectsPreset: EffectsPreset = EffectsPreset(),
         noiseSuppression: NoiseSuppressionSettings = NoiseSuppressionSettings()) {
        self.sources = sources
        self.outputChannels = outputChannels
        self.streamOutputChannels = streamOutputChannels
        self.streamMixEnabled = streamMixEnabled
        self.routes = routes
        self.outputDestinations = outputDestinations
        self.effectsPreset = effectsPreset
        self.noiseSuppression = noiseSuppression
    }

    // Backward-compatible decoding: newer keys may not exist in old configs
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sources = try container.decode([AudioSource].self, forKey: .sources)
        outputChannels = try container.decode([AudioChannel].self, forKey: .outputChannels)
        streamOutputChannels = (try? container.decode([AudioChannel].self, forKey: .streamOutputChannels)) ?? []
        streamMixEnabled = (try? container.decode(Bool.self, forKey: .streamMixEnabled)) ?? false
        routes = try container.decode([AudioRoute].self, forKey: .routes)
        outputDestinations = (try? container.decode([OutputDestination].self, forKey: .outputDestinations)) ?? []
        effectsPreset = (try? container.decode(EffectsPreset.self, forKey: .effectsPreset)) ?? EffectsPreset()
        noiseSuppression = (try? container.decode(NoiseSuppressionSettings.self, forKey: .noiseSuppression))
            ?? NoiseSuppressionSettings()
    }
}

// MARK: - Routing state (the entire app model)

class RoutingState: ObservableObject {
    @Published var sources: [AudioSource]
    @Published var outputChannels: [AudioChannel]
    /// Stream Mix's own channel pairs, independent of the virtual mic's. Empty until the user
    /// first enables Stream Mix (`setStreamMixEnabled(true)`), which seeds a default pair.
    @Published var streamOutputChannels: [AudioChannel]
    /// Whether the Stream Mix column is shown in the routing canvas. Off by default so existing
    /// users see no change; routes into Stream Mix are kept (just hidden) while this is false.
    @Published var streamMixEnabled: Bool
    @Published var routes: [AudioRoute]
    @Published var outputDestinations: [OutputDestination]
    @Published var effectsPreset: EffectsPreset
    @Published var noiseSuppression: NoiseSuppressionSettings
    /// Currently selected connector for route creation (first click)
    @Published var pendingConnector: ConnectorEnd?

    /// Positions of connector dots, reported via PreferenceKey
    @Published var connectorPositions: [ConnectorEnd: CGPoint] = [:]

    init(
        sources: [AudioSource] = [],
        outputChannels: [AudioChannel] = [],
        streamOutputChannels: [AudioChannel] = [],
        streamMixEnabled: Bool = false,
        routes: [AudioRoute] = [],
        outputDestinations: [OutputDestination] = [],
        effectsPreset: EffectsPreset = EffectsPreset(),
        noiseSuppression: NoiseSuppressionSettings = NoiseSuppressionSettings()
    ) {
        self.sources = sources
        self.outputChannels = outputChannels
        self.streamOutputChannels = streamOutputChannels
        self.streamMixEnabled = streamMixEnabled
        self.routes = routes
        self.outputDestinations = outputDestinations
        self.effectsPreset = effectsPreset
        self.noiseSuppression = noiseSuppression
    }

    // MARK: - Route management

    func addRoute(sourceId: UUID, sourceChannelId: Int, targetId: RouteTarget = .virtualMic, outputChannelId: Int) {
        let exists = routes.contains {
            $0.sourceId == sourceId &&
            $0.sourceChannelId == sourceChannelId &&
            $0.targetId == targetId &&
            $0.outputChannelId == outputChannelId
        }
        guard !exists else { return }
        let route = AudioRoute(sourceId: sourceId, sourceChannelId: sourceChannelId, targetId: targetId,
                               outputChannelId: outputChannelId)
        routes.append(route)
        save()
    }

    func removeRoute(id: UUID) {
        routes.removeAll { $0.id == id }
        save()
    }

    func removeRoutesFor(connector: ConnectorEnd) {
        switch connector {
        case .source(let sid, let ch):
            routes.removeAll { $0.sourceId == sid && $0.sourceChannelId == ch }
        case .output(let target, let ch):
            routes.removeAll { $0.targetId == target && $0.outputChannelId == ch }
        }
        save()
    }

    func findRoute(from a: ConnectorEnd, to b: ConnectorEnd) -> AudioRoute? {
        let (src, out): (ConnectorEnd, ConnectorEnd)
        switch (a, b) {
        case (.source, .output): (src, out) = (a, b)
        case (.output, .source): (src, out) = (b, a)
        default: return nil
        }
        guard case .source(let sid, let sch) = src,
              case .output(let target, let och) = out else { return nil }
        return routes.first { $0.sourceId == sid && $0.sourceChannelId == sch && $0.targetId == target && $0.outputChannelId == och }
    }

    func removeRouteBetween(from a: ConnectorEnd, to b: ConnectorEnd) {
        if let route = findRoute(from: a, to: b) {
            routes.removeAll { $0.id == route.id }
            save()
        }
    }

    func removeSource(_ sourceId: UUID) {
        sources.removeAll { $0.id == sourceId }
        routes.removeAll { $0.sourceId == sourceId }
        save()
    }

    func toggleSource(_ sourceId: UUID) {
        guard let idx = sources.firstIndex(where: { $0.id == sourceId }) else { return }
        sources[idx].isEnabled.toggle()
        save()
    }

    /// Re-binds device sources whose saved UID no longer exists to a present input
    /// device with the same name. CoreAudio UIDs change when a different driver
    /// claims the hardware (e.g. MOTU's CoreUAC driver vs. AppleUSBAudioEngine),
    /// which would otherwise leave the source silently unroutable.
    /// A source is only re-bound when exactly one unclaimed input device matches.
    /// Returns the (old, new) UID pairs that changed.
    @discardableResult
    func rebindMissingDeviceSources(to devices: [SystemAudioDevice]) -> [(old: String, new: String)] {
        let presentUIDs = Set(devices.map(\.uid))
        var claimedUIDs = Set(sources.map(\.deviceUID))
        var changes: [(old: String, new: String)] = []

        for idx in sources.indices {
            let source = sources[idx]
            guard !source.isAppCapture, !source.deviceUID.isEmpty,
                  !presentUIDs.contains(source.deviceUID) else { continue }
            let candidates = devices.filter {
                $0.isInput && $0.name == source.name && !claimedUIDs.contains($0.uid)
            }
            guard candidates.count == 1, let match = candidates.first else { continue }
            claimedUIDs.insert(match.uid)
            changes.append((old: source.deviceUID, new: match.uid))
            sources[idx].deviceUID = match.uid
        }

        if !changes.isEmpty { save() }
        return changes
    }

    func addOutputChannel() {
        let nextId = (outputChannels.map(\.id).max() ?? 0) + 1
        let label: String
        if nextId % 2 == 1 {
            label = "\(nextId) (L)"
        } else {
            label = "\(nextId) (R)"
        }
        outputChannels.append(AudioChannel(id: nextId, label: label))
        save()
    }

    func removeOutputChannel(_ channelId: Int) {
        outputChannels.removeAll { $0.id == channelId }
        routes.removeAll { $0.targetId == .virtualMic && $0.outputChannelId == channelId }
        save()
    }

    /// Channels the virtual mic device should expose: the UI's channels rounded up to a pair.
    var micChannelCount: Int {
        VirtualDeviceChannels.deviceCount(forChannels: outputChannels.count)
    }

    /// Grow the virtual mic by one stereo pair (up to the driver's 16-channel limit).
    func addOutputChannelPair() {
        let target = min(VirtualDeviceChannels.maxCount, (outputChannels.count / 2 + 1) * 2)
        while outputChannels.count < target { addOutputChannel() }
    }

    /// Drop the last pair (or the odd leftover channel) and the routes into it; never below 2.
    func removeLastOutputChannelPair() {
        let target = max(2, (outputChannels.count - 1) / 2 * 2)
        let doomed = outputChannels.sorted { $0.id < $1.id }.dropFirst(target).map(\.id)
        outputChannels.removeAll { doomed.contains($0.id) }
        routes.removeAll { $0.targetId == .virtualMic && doomed.contains($0.outputChannelId) }
        save()
    }

    // MARK: - Stream Mix channel management (same model as the virtual mic, separate channel space)

    /// Shows the Stream Mix column, seeding a default stereo pair the first time it's enabled.
    /// Disabling keeps its channels and routes (just hidden) so re-enabling restores them.
    func setStreamMixEnabled(_ enabled: Bool) {
        streamMixEnabled = enabled
        if enabled && streamOutputChannels.isEmpty {
            streamOutputChannels = [AudioChannel(id: 1, label: "1 (L)"), AudioChannel(id: 2, label: "2 (R)")]
        }
        save()
    }

    func addStreamOutputChannel() {
        let nextId = (streamOutputChannels.map(\.id).max() ?? 0) + 1
        let label = nextId % 2 == 1 ? "\(nextId) (L)" : "\(nextId) (R)"
        streamOutputChannels.append(AudioChannel(id: nextId, label: label))
        save()
    }

    func removeStreamOutputChannel(_ channelId: Int) {
        streamOutputChannels.removeAll { $0.id == channelId }
        routes.removeAll { $0.targetId == .streamMix && $0.outputChannelId == channelId }
        save()
    }

    /// Channels the Stream Mix device should expose: its channels rounded up to a pair.
    var streamMicChannelCount: Int {
        VirtualDeviceChannels.deviceCount(forChannels: streamOutputChannels.count)
    }

    func addStreamOutputChannelPair() {
        let target = min(VirtualDeviceChannels.maxCount, (streamOutputChannels.count / 2 + 1) * 2)
        while streamOutputChannels.count < target { addStreamOutputChannel() }
    }

    func removeLastStreamOutputChannelPair() {
        let target = max(2, (streamOutputChannels.count - 1) / 2 * 2)
        let doomed = streamOutputChannels.sorted { $0.id < $1.id }.dropFirst(target).map(\.id)
        streamOutputChannels.removeAll { doomed.contains($0.id) }
        routes.removeAll { $0.targetId == .streamMix && doomed.contains($0.outputChannelId) }
        save()
    }

    /// Set an output destination's device width, keeping its monitor pair inside it.
    func setOutputDestinationChannels(id: UUID, channelCount: Int) {
        guard let idx = outputDestinations.firstIndex(where: { $0.id == id }) else { return }
        outputDestinations[idx].channelCount = channelCount
        outputDestinations[idx].monitorChannel = min(outputDestinations[idx].monitorChannel, channelCount - 1)
        save()
    }

    func setOutputDestinationMonitorChannel(id: UUID, monitorChannel: Int) {
        guard let idx = outputDestinations.firstIndex(where: { $0.id == id }) else { return }
        outputDestinations[idx].monitorChannel = monitorChannel
        save()
    }

    // MARK: - Output destination management

    func addOutputDestination(virtualDeviceUID: String, virtualDeviceName: String,
                              physicalOutputUID: String = "", physicalOutputName: String = "None") {
        let exists = outputDestinations.contains { $0.virtualDeviceUID == virtualDeviceUID }
        guard !exists else { return }
        let dest = OutputDestination(
            virtualDeviceUID: virtualDeviceUID,
            virtualDeviceName: virtualDeviceName,
            physicalOutputUID: physicalOutputUID,
            physicalOutputName: physicalOutputName
        )
        outputDestinations.append(dest)
        save()
    }

    func removeOutputDestination(id: UUID) {
        outputDestinations.removeAll { $0.id == id }
        save()
    }

    func toggleOutputDestination(id: UUID) {
        guard let idx = outputDestinations.firstIndex(where: { $0.id == id }) else { return }
        outputDestinations[idx].isEnabled.toggle()
        save()
    }

    func handleConnectorTap(_ connector: ConnectorEnd) {
        guard let pending = pendingConnector else {
            pendingConnector = connector
            return
        }

        // Must be source -> output or output -> source
        switch (pending, connector) {
        case (.source(let sid, let sch), .output(let target, let och)):
            addRoute(sourceId: sid, sourceChannelId: sch, targetId: target, outputChannelId: och)
        case (.output(let target, let och), .source(let sid, let sch)):
            addRoute(sourceId: sid, sourceChannelId: sch, targetId: target, outputChannelId: och)
        default:
            break // same side, ignore
        }
        pendingConnector = nil
    }

    func cancelPendingConnection() {
        pendingConnector = nil
    }

    /// Remove all routes but keep sources intact
    func disconnectAll() {
        routes.removeAll()
        save()
    }

    // MARK: - Persistence

    private static let configDirectoryURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Loopbacker", isDirectory: true)
    }()

    private static let configFileURL: URL = {
        configDirectoryURL.appendingPathComponent("config.json")
    }()

    /// Serial background queue for config persistence -- avoids blocking
    /// the main thread with file I/O during rapid state changes.
    private static let saveQueue = DispatchQueue(label: "com.jacobcoffee.loopbacker.save", qos: .utility)

    func save() {
        // Snapshot the config on the calling thread (main), then write on background.
        let config = RoutingConfig(
            sources: sources,
            outputChannels: outputChannels,
            streamOutputChannels: streamOutputChannels,
            streamMixEnabled: streamMixEnabled,
            routes: routes,
            outputDestinations: outputDestinations,
            effectsPreset: effectsPreset,
            noiseSuppression: noiseSuppression
        )
        Self.saveQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: Self.configDirectoryURL,
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(config)
                try data.write(to: Self.configFileURL, options: .atomic)
            } catch {
                // Non-fatal: best-effort persistence
                print("Loopbacker: failed to save config: \(error)")
            }
        }
    }

    static func load() -> RoutingState {
        do {
            let data = try Data(contentsOf: configFileURL)
            let config = try JSONDecoder().decode(RoutingConfig.self, from: data)
            return RoutingState(
                sources: config.sources,
                outputChannels: config.outputChannels,
                streamOutputChannels: config.streamOutputChannels,
                streamMixEnabled: config.streamMixEnabled,
                routes: config.routes,
                outputDestinations: config.outputDestinations,
                effectsPreset: config.effectsPreset,
                noiseSuppression: config.noiseSuppression
            )
        } catch {
            // No saved state or corrupt file — fall back to defaults
            return empty()
        }
    }

    // MARK: - Mute / Solo

    func muteSource(_ sourceId: UUID) {
        guard let idx = sources.firstIndex(where: { $0.id == sourceId }) else { return }
        sources[idx].isMuted.toggle()
        save()
    }

    func soloSource(_ sourceId: UUID) {
        for i in sources.indices {
            sources[i].isMuted = sources[i].id != sourceId
        }
        save()
    }

    // MARK: - Export / Import

    /// Encodes the current routing configuration to JSON data.
    func exportConfig() -> Data {
        let config = RoutingConfig(
            sources: sources,
            outputChannels: outputChannels,
            streamOutputChannels: streamOutputChannels,
            streamMixEnabled: streamMixEnabled,
            routes: routes,
            outputDestinations: outputDestinations,
            effectsPreset: effectsPreset,
            noiseSuppression: noiseSuppression
        )
        return (try? JSONEncoder().encode(config)) ?? Data()
    }

    /// Decodes and replaces the current routing state from JSON data.
    func importConfig(_ data: Data) {
        guard let config = try? JSONDecoder().decode(RoutingConfig.self, from: data) else { return }
        sources = config.sources
        outputChannels = config.outputChannels
        streamOutputChannels = config.streamOutputChannels
        streamMixEnabled = config.streamMixEnabled
        routes = config.routes
        outputDestinations = config.outputDestinations
        effectsPreset = config.effectsPreset
        noiseSuppression = config.noiseSuppression
        save()
    }

    // MARK: - Empty initial state (populated from real devices on launch)

    static func empty() -> RoutingState {
        RoutingState(
            sources: [],
            outputChannels: [
                AudioChannel(id: 1, label: "1 (L)"),
                AudioChannel(id: 2, label: "2 (R)")
            ],
            routes: []
        )
    }
}

// MARK: - Preset Manager

struct PresetManager {
    private static let presetsDirectoryURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Loopbacker", isDirectory: true)
            .appendingPathComponent("presets", isDirectory: true)
    }()

    /// Save a named preset from the given data.
    static func save(name: String, data: Data) {
        do {
            try FileManager.default.createDirectory(
                at: presetsDirectoryURL,
                withIntermediateDirectories: true
            )
            let fileURL = presetsDirectoryURL.appendingPathComponent(sanitizedFileName(name))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Loopbacker: failed to save preset '\(name)': \(error)")
        }
    }

    /// Load a named preset, returning its raw JSON data.
    static func load(name: String) -> Data? {
        let fileURL = presetsDirectoryURL.appendingPathComponent(sanitizedFileName(name))
        return try? Data(contentsOf: fileURL)
    }

    /// List all saved preset names (without the .json extension).
    static func list() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: presetsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .sorted { a, b in
                let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return aDate > bDate
            }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    /// Delete a named preset.
    static func delete(name: String) {
        let fileURL = presetsDirectoryURL.appendingPathComponent(sanitizedFileName(name))
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let safe = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(safe).json"
    }
}
