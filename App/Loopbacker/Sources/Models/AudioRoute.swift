import Foundation
import SwiftUI
import Combine

struct AudioRoute: Identifiable, Equatable, Codable {
    let id: UUID
    var sourceId: UUID
    var sourceChannelId: Int
    var outputChannelId: Int

    init(id: UUID = UUID(), sourceId: UUID, sourceChannelId: Int, outputChannelId: Int) {
        self.id = id
        self.sourceId = sourceId
        self.sourceChannelId = sourceChannelId
        self.outputChannelId = outputChannelId
    }
}

// MARK: - Connector identity for cable routing

enum ConnectorEnd: Equatable, Hashable {
    case source(sourceId: UUID, channelId: Int)
    case output(channelId: Int)

    func hash(into hasher: inout Hasher) {
        switch self {
        case .source(let sid, let ch):
            hasher.combine(0)
            hasher.combine(sid)
            hasher.combine(ch)
        case .output(let ch):
            hasher.combine(1)
            hasher.combine(ch)
        }
    }
}

// MARK: - Persistable routing configuration

struct RoutingConfig: Codable {
    var sources: [AudioSource]
    var outputChannels: [AudioChannel]
    var routes: [AudioRoute]
    var outputDestinations: [OutputDestination]
    var effectsPreset: EffectsPreset

    init(sources: [AudioSource], outputChannels: [AudioChannel], routes: [AudioRoute],
         outputDestinations: [OutputDestination] = [], effectsPreset: EffectsPreset = EffectsPreset()) {
        self.sources = sources
        self.outputChannels = outputChannels
        self.routes = routes
        self.outputDestinations = outputDestinations
        self.effectsPreset = effectsPreset
    }

    // Backward-compatible decoding: outputDestinations/effectsPreset may not exist in old configs
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sources = try container.decode([AudioSource].self, forKey: .sources)
        outputChannels = try container.decode([AudioChannel].self, forKey: .outputChannels)
        routes = try container.decode([AudioRoute].self, forKey: .routes)
        outputDestinations = (try? container.decode([OutputDestination].self, forKey: .outputDestinations)) ?? []
        effectsPreset = (try? container.decode(EffectsPreset.self, forKey: .effectsPreset)) ?? EffectsPreset()
    }
}

// MARK: - Routing state (the entire app model)

class RoutingState: ObservableObject {
    @Published var sources: [AudioSource]
    @Published var outputChannels: [AudioChannel]
    @Published var routes: [AudioRoute]
    @Published var outputDestinations: [OutputDestination]
    @Published var effectsPreset: EffectsPreset
    /// Currently selected connector for route creation (first click)
    @Published var pendingConnector: ConnectorEnd?

    /// Positions of connector dots, reported via PreferenceKey
    @Published var connectorPositions: [ConnectorEnd: CGPoint] = [:]

    init(
        sources: [AudioSource] = [],
        outputChannels: [AudioChannel] = [],
        routes: [AudioRoute] = [],
        outputDestinations: [OutputDestination] = [],
        effectsPreset: EffectsPreset = EffectsPreset()
    ) {
        self.sources = sources
        self.outputChannels = outputChannels
        self.routes = routes
        self.outputDestinations = outputDestinations
        self.effectsPreset = effectsPreset
    }

    // MARK: - Route management

    func addRoute(sourceId: UUID, sourceChannelId: Int, outputChannelId: Int) {
        let exists = routes.contains {
            $0.sourceId == sourceId &&
            $0.sourceChannelId == sourceChannelId &&
            $0.outputChannelId == outputChannelId
        }
        guard !exists else { return }
        let route = AudioRoute(sourceId: sourceId, sourceChannelId: sourceChannelId, outputChannelId: outputChannelId)
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
        case .output(let ch):
            routes.removeAll { $0.outputChannelId == ch }
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
              case .output(let och) = out else { return nil }
        return routes.first { $0.sourceId == sid && $0.sourceChannelId == sch && $0.outputChannelId == och }
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
        routes.removeAll { $0.outputChannelId == channelId }
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
        case (.source(let sid, let sch), .output(let och)):
            addRoute(sourceId: sid, sourceChannelId: sch, outputChannelId: och)
        case (.output(let och), .source(let sid, let sch)):
            addRoute(sourceId: sid, sourceChannelId: sch, outputChannelId: och)
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
            routes: routes,
            outputDestinations: outputDestinations,
            effectsPreset: effectsPreset
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
                routes: config.routes,
                outputDestinations: config.outputDestinations,
                effectsPreset: config.effectsPreset
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
            routes: routes,
            outputDestinations: outputDestinations,
            effectsPreset: effectsPreset
        )
        return (try? JSONEncoder().encode(config)) ?? Data()
    }

    /// Decodes and replaces the current routing state from JSON data.
    func importConfig(_ data: Data) {
        guard let config = try? JSONDecoder().decode(RoutingConfig.self, from: data) else { return }
        sources = config.sources
        outputChannels = config.outputChannels
        routes = config.routes
        outputDestinations = config.outputDestinations
        effectsPreset = config.effectsPreset
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
