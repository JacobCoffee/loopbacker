import AppKit
import CoreAudio
import Darwin

/// Maps apps to the processes that actually play their audio. Many apps don't play from their
/// main process: Discord and Slack (Electron) play from `com.hnc.Discord.helper.Renderer`-style
/// helpers, Chrome and Edge from `….helper` processes, Firefox from `plugin-container`. A process
/// tap keyed only by the app's own bundle ID hears nothing from them.
enum AudioProcessResolver {
    struct AudioClient: Equatable {
        let pid: pid_t
        let bundleID: String
    }

    /// Bundle IDs a process tap needs to cover `appBundleIDs`: the apps' own IDs (so a relaunch
    /// is picked up), plus every CoreAudio client process that belongs to one of them.
    static func tapBundleIDs(for appBundleIDs: Set<String>) -> Set<String> {
        guard !appBundleIDs.isEmpty else { return [] }
        var appPIDs: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, appBundleIDs.contains(id) { appPIDs[app.processIdentifier] = id }
        }
        return match(clients: audioClients(), apps: appBundleIDs, appPIDs: appPIDs, parentOf: parentPID)
    }

    /// A client belongs to an app when its bundle ID is the app's or extends it
    /// (`com.hnc.Discord.helper.Renderer` for `com.hnc.Discord`), or when the app's main
    /// process is among its ancestors (Firefox's `org.mozilla.plugincontainer`).
    static func match(
        clients: [AudioClient], apps: Set<String>, appPIDs: [pid_t: String],
        parentOf: (pid_t) -> pid_t?
    ) -> Set<String> {
        var result = apps
        for client in clients where !client.bundleID.isEmpty {
            if apps.contains(where: { client.bundleID == $0 || client.bundleID.hasPrefix($0 + ".") }) {
                result.insert(client.bundleID)
                continue
            }
            var pid = client.pid
            for _ in 0..<8 {
                guard let parent = parentOf(pid), parent > 1 else { break }
                if appPIDs[parent] != nil {
                    result.insert(client.bundleID)
                    break
                }
                pid = parent
            }
        }
        return result
    }

    /// Every process CoreAudio currently knows as an audio client.
    static func audioClients() -> [AudioClient] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        return objects.compactMap { object in
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr else { return nil }

            var idAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var bundleID: Unmanaged<CFString>?
            var idSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(object, &idAddress, 0, nil, &idSize, &bundleID) == noErr,
                  let id = bundleID?.takeRetainedValue() as String? else { return nil }
            return AudioClient(pid: pid, bundleID: id)
        }
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

/// Calls `onChange` on the main actor whenever CoreAudio's process list changes (an app or
/// helper starts or stops being an audio client), so taps can pick up helpers that appear later,
/// like Discord's voice process when you join a call.
@MainActor
final class AudioProcessListObserver {
    private var block: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    func start(_ onChange: @escaping @MainActor () -> Void) {
        guard block == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { onChange() }
        }
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr else { return }
        block = listener
    }

    func stop() {
        guard let block else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        self.block = nil
    }
}
