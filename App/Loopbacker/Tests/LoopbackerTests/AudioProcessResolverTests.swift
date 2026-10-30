import Darwin
import Testing
@testable import Loopbacker

@Suite("AudioProcessResolver: which processes play an app's audio")
struct AudioProcessResolverTests {
    private typealias Client = AudioProcessResolver.AudioClient

    @Test("Electron helpers count as their app: Discord's voice plays from its Renderer helper")
    func bundleIDPrefixHelpers() {
        let clients = [
            Client(pid: 19143, bundleID: "com.hnc.Discord.helper.Renderer"),
            Client(pid: 19123, bundleID: "com.hnc.Discord"),
            Client(pid: 50413, bundleID: "com.spotify.client"),
            Client(pid: 70000, bundleID: "com.hnc.DiscordCanary"),
        ]
        let result = AudioProcessResolver.match(
            clients: clients, apps: ["com.hnc.Discord"], appPIDs: [19123: "com.hnc.Discord"], parentOf: { _ in 1 })
        #expect(result == ["com.hnc.Discord", "com.hnc.Discord.helper.Renderer"])
    }

    @Test("A child process with an unrelated bundle ID counts: Firefox plays from plugin-container")
    func descendantProcesses() {
        let parents: [pid_t: pid_t] = [300: 200, 200: 100, 400: 1]
        let clients = [
            Client(pid: 300, bundleID: "org.mozilla.plugincontainer"),
            Client(pid: 400, bundleID: "com.apple.WebKit.GPU"),
        ]
        let result = AudioProcessResolver.match(
            clients: clients, apps: ["org.mozilla.firefox"], appPIDs: [100: "org.mozilla.firefox"],
            parentOf: { parents[$0] })
        #expect(result == ["org.mozilla.firefox", "org.mozilla.plugincontainer"])
    }
}
