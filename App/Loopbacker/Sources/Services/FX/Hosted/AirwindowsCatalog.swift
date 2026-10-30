import CAirwindows
import Foundation

/// Lists the vendored Airwindows effect suite (`CAirwindows/autogen_airwin`, ~528 effects) for
/// the effect browser. Scanning is just reading the registry's static metadata — no instances are
/// created, so this is cheap and synchronous under the hood.
enum AirwindowsCatalog: FXPluginCatalog {
    static func scan() async -> [FXPluginInfo] {
        guard AirwindowsLibrary.isEnabled else { return [] }

        let count = Int(aw_effect_count())
        var out: [FXPluginInfo] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let index = Int32(i)
            let name = String(cString: aw_effect_name(index))
            guard !name.isEmpty else { continue }
            let category = String(cString: aw_effect_category(index))
            let whatText = String(cString: aw_effect_what_text(index))
            let ref = FXPluginRef(format: .airwindows, identifier: name, name: name, vendor: "Airwindows")
            out.append(FXPluginInfo(
                ref: ref,
                category: category.isEmpty ? nil : category,
                summary: whatText.isEmpty ? nil : whatText
            ))
        }
        return out
    }
}
