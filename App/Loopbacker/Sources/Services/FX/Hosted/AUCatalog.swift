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
///
/// Trust model (LB-HOST-001, see also `AUHostNode`'s header comment): the maintainer has
/// chosen in-process v2 hosting (`AudioComponentInstanceNew`, `com.apple.security.cs.disable-
/// library-validation`) over out-of-process hosting, for the measured render-path allocation
/// cost `AUAudioUnit`'s v2 bridge adds — see `AUHostNode`'s doc comment for the measurement.
/// That means any installed `aufx`/`aumf` component, including one a user-writable process
/// drops into `~/Library/Audio/Plug-Ins/Components` with no TCC grant of its own, runs as
/// Loopbacker and inherits Loopbacker's microphone/system-audio permissions once it is
/// instantiated. This file does not change that decision; it removes the one place the old
/// scan code instantiated *every* installed component merely to list it, which multiplied the
/// exposure far beyond what the user actually asked for (`EffectBrowserSheet`'s `.task` reruns
/// `scan()` every time the effect browser opens, not just once). `scan()` below only reads
/// `AVAudioUnitComponent` metadata (name, tags, `supportsNumberInputChannels(_:outputChannels:)`)
/// — it never creates an `AUAudioUnit`/`AudioComponentInstance`. The first and only point a
/// component is actually instantiated is `AUHostNode.load`, called when the user picks a
/// plugin in the browser or when a persisted chain is built (including at launch) — the latter
/// being the explicit, user-controlled trust boundary: a component that was already part of
/// the user's saved chain the last time they ran Loopbacker.
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
                guard supportsVoiceChannels(component) else { continue }
                infos.append(pluginInfo(for: component))
            }
        }
        return infos
    }

    /// Metadata-only channel check (LB-HOST-001): `AVAudioUnitComponent.supportsNumberInput
    /// Channels(_:outputChannels:)` reads the component's declared channel-capability info
    /// property, never instantiating it. Stereo or mono in/out is what `AUHostNode`'s v2/v3
    /// loaders actually negotiate (`configure(2)` then `configure(1)`), so this mirrors that
    /// contract without paying its instantiation cost at scan time; a component that declares
    /// support here but turns out not to actually negotiate either format still surfaces as a
    /// normal load error from `AUHostNode.load` when the user picks it, exactly as a component
    /// this check skipped would have failed `supportsVoiceChannels`'s old instantiate-and-probe
    /// version.
    private static func supportsVoiceChannels(_ component: AVAudioUnitComponent) -> Bool {
        component.supportsNumberInputChannels(2, outputChannels: 2)
            || component.supportsNumberInputChannels(1, outputChannels: 1)
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
