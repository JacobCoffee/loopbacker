import Foundation

/// Whether Airwindows effects appear in the effect browser at all. Persisted: users who don't
/// want ~500 extra entries in the plugin picker can turn the whole library off. Honoured by
/// `AirwindowsCatalog.scan()`; does not affect effects already loaded into a running chain.
enum AirwindowsLibrary {
    private static let defaultsKey = "AirwindowsLibrary.isEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}
