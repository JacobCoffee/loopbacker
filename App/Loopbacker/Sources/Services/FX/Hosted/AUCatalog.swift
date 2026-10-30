import AudioToolbox
import AVFoundation

/// Converts between the three-FourCC `FXPluginRef.identifier` format (`"aufx dely appl"`) and
/// the `OSType` triple `AudioComponentDescription` uses.
enum AUFourCC {
    static func parse(_ identifier: String) throws -> (type: OSType, subType: OSType, manufacturer: OSType) {
        let parts = identifier.split(separator: " ")
        guard parts.count == 3 else { throw AUHostError.malformedIdentifier(identifier) }
        func code(_ part: Substring) throws -> OSType {
            guard part.utf8.count == 4 else { throw AUHostError.malformedIdentifier(identifier) }
            return part.utf8.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
        }
        return (try code(parts[0]), try code(parts[1]), try code(parts[2]))
    }

    static func string(_ code: OSType) -> String {
        let bytes = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
        return String(decoding: bytes, as: UTF8.self)
    }

    static func identifier(_ description: AudioComponentDescription) -> String {
        "\(string(description.componentType)) \(string(description.componentSubType)) \(string(description.componentManufacturer))"
    }
}

/// Lists installed effect Audio Units (`aufx`, `aumf`) that can run our voice pair at 48 kHz.
enum AUCatalog: FXPluginCatalog {
    static func scan() async -> [FXPluginInfo] {
        let manager = AVAudioUnitComponentManager.shared()
        var infos: [FXPluginInfo] = []
        // componentSubType/componentManufacturer 0 is the documented AudioComponent wildcard:
        // match every subtype/vendor of the given type.
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let query = AudioComponentDescription(
                componentType: type, componentSubType: 0, componentManufacturer: 0,
                componentFlags: 0, componentFlagsMask: 0)
            for component in manager.components(matching: query) {
                guard supportsVoiceChannels(component.audioComponentDescription) else { continue }
                infos.append(pluginInfo(for: component))
            }
        }
        return infos
    }

    /// A throwaway, unconfigured instance just to read `inputBusses`/`outputBusses` channel
    /// support; discarded immediately. Not on any audio thread, so an AU-defined cost here
    /// (even one that opens resources) is acceptable for a one-time scan.
    private static func supportsVoiceChannels(_ description: AudioComponentDescription) -> Bool {
        guard let au = try? AUAudioUnit(componentDescription: description, options: []),
              au.inputBusses.count > 0, au.outputBusses.count > 0 else { return false }
        let inBus = au.inputBusses[0]
        let outBus = au.outputBusses[0]
        func fits(_ channels: AVAudioChannelCount) -> Bool {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels) else { return false }
            return (try? inBus.setFormat(format)) != nil && (try? outBus.setFormat(format)) != nil
        }
        return fits(2) || fits(1)
    }

    private static func pluginInfo(for component: AVAudioUnitComponent) -> FXPluginInfo {
        let description = component.audioComponentDescription
        let ref = FXPluginRef(
            format: .audioUnit,
            identifier: AUFourCC.identifier(description),
            name: component.name,
            vendor: component.manufacturerName)
        let isAUv3 = AudioComponentFlags(rawValue: description.componentFlags).contains(.isV3AudioUnit)
        let category = component.allTagNames.sorted().first
            ?? (description.componentType == kAudioUnitType_MusicEffect ? "Music Effect" : "Effect")
        return FXPluginInfo(ref: ref, category: category, summary: nil, isAUv3: isAUv3)
    }
}
