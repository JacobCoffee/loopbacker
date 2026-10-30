import Foundation
import Observation

/// A loudness target band: where the user wants their virtual mic to sit, in LUFS.
enum LoudnessTarget: String, Codable, CaseIterable, Identifiable {
    /// Podcast/voice calls: -16 LUFS, the common streaming/podcast recommendation.
    case voice
    /// EBU R128 broadcast: -23 LUFS.
    case broadcast
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .voice: "Voice/Podcast (-16 LUFS)"
        case .broadcast: "Broadcast EBU R128 (-23 LUFS)"
        case .custom: "Custom"
        }
    }

    /// LUFS this preset targets; `.custom` is resolved by the caller's stored custom value.
    var lufs: Float? {
        switch self {
        case .voice: -16
        case .broadcast: -23
        case .custom: nil
        }
    }
}

/// How a momentary/short-term reading compares to the target band. On target is within ±1 LU.
enum LoudnessStatus {
    case tooQuiet, onTarget, tooLoud, noSignal

    var label: String {
        switch self {
        case .tooQuiet: "Too quiet"
        case .onTarget: "On target"
        case .tooLoud: "Too loud"
        case .noSignal: "No signal"
        }
    }

    init(level: Float, targetLUFS: Float) {
        guard level.isFinite else {
            self = .noSignal
            return
        }
        let delta = level - targetLUFS
        if delta < -1 { self = .tooQuiet }
        else if delta > 1 { self = .tooLoud }
        else { self = .onTarget }
    }
}

/// One virtual device's live loudness reading, published at the router's meter tick.
struct LoudnessReading: Equatable {
    var momentaryLUFS: Float = -.infinity
    var shortTermLUFS: Float = -.infinity
    var integratedLUFS: Float = -.infinity
    var truePeakDBTP: Float = -.infinity
}

/// Live loudness readings for each measured virtual device, plus the user's target band.
/// Mirrors `MeterLevels`: written by `AudioRouter`'s meter timer (already gated by window
/// visibility), read by SwiftUI. Readings update at most every 100 ms (one BS.1770 gating step),
/// far below the cost `MeterLevels`' continuous bar meters guard against, so plain `@Observable`
/// text-driven SwiftUI updates (no Core Animation layer) are cheap enough here.
@MainActor
@Observable
final class LoudnessLevels {
    private static let targetKey = "com.jacobcoffee.loopbacker.loudness.target"
    private static let customTargetKey = "com.jacobcoffee.loopbacker.loudness.customTargetLUFS"

    nonisolated init() {}

    private(set) var readings: [String: LoudnessReading] = [:]

    /// Self-persisted in `UserDefaults` (loaded lazily on first access) rather than threaded
    /// through `RoutingConfig`: it's a display preference for this meter, not audio-affecting
    /// routing state.
    var target: LoudnessTarget = {
        UserDefaults.standard.string(forKey: LoudnessLevels.targetKey).flatMap(LoudnessTarget.init) ?? .voice
    }() {
        didSet { UserDefaults.standard.set(target.rawValue, forKey: Self.targetKey) }
    }
    var customTargetLUFS: Float = {
        let hasStored = UserDefaults.standard.object(forKey: LoudnessLevels.customTargetKey) != nil
        let stored = UserDefaults.standard.double(forKey: LoudnessLevels.customTargetKey)
        return hasStored ? Float(stored) : -16
    }() {
        didSet { UserDefaults.standard.set(Double(customTargetLUFS), forKey: Self.customTargetKey) }
    }

    var effectiveTargetLUFS: Float { target.lufs ?? customTargetLUFS }

    func reading(deviceUID: String) -> LoudnessReading {
        readings[deviceUID] ?? LoudnessReading()
    }

    func status(deviceUID: String) -> LoudnessStatus {
        let r = reading(deviceUID: deviceUID)
        let level = r.shortTermLUFS.isFinite ? r.shortTermLUFS : r.momentaryLUFS
        return LoudnessStatus(level: level, targetLUFS: effectiveTargetLUFS)
    }

    func update(deviceUID: String, _ reading: LoudnessReading) {
        if readings[deviceUID] != reading { readings[deviceUID] = reading }
    }

    func clear(deviceUID: String) {
        readings.removeValue(forKey: deviceUID)
    }
}
