import Foundation
import Testing
@testable import Loopbacker

/// `EffectsPresetManager.importData` rejects oversized/untrusted preset files before they reach
/// any hosted-plugin loader (LB-RES-001): file size, node count, and per-node `pluginState` size.
@Suite("EffectsPresetManager import limits")
struct EffectsPresetImportTests {
    @Test("A well-formed, modest preset imports successfully")
    func validPresetImports() throws {
        let preset = EffectsPreset(isEnabled: true, nodes: [FXNodeConfig(kind: .gate)])
        let data = try #require(EffectsPresetManager.exportData(preset: preset))
        switch EffectsPresetManager.importData(data) {
        case .success(let imported):
            #expect(imported.nodes.count == 1)
        case .failure(let error):
            Issue.record("expected success, got \(error)")
        }
    }

    @Test("A file over the 4 MB size cap is rejected before decoding")
    func oversizedFileRejected() {
        var data = Data("{\"version\":2,\"isEnabled\":false,\"nodes\":[".utf8)
        data.append(Data(repeating: UInt8(ascii: " "), count: EffectsPresetManager.maxImportFileSize + 1))
        data.append(Data("],\"appAudio\":{}}".utf8))
        guard case .failure(.tooLarge(let bytes)) = EffectsPresetManager.importData(data) else {
            Issue.record("expected .tooLarge")
            return
        }
        #expect(bytes == data.count)
    }

    @Test("More than 64 nodes is rejected")
    func tooManyNodesRejected() throws {
        let nodes = (0..<(EffectsPresetManager.maxImportNodeCount + 1)).map { _ in FXNodeConfig(kind: .gate) }
        let preset = EffectsPreset(isEnabled: true, nodes: nodes)
        let data = try #require(EffectsPresetManager.exportData(preset: preset))
        guard case .failure(.tooManyNodes(let count)) = EffectsPresetManager.importData(data) else {
            Issue.record("expected .tooManyNodes")
            return
        }
        #expect(count == nodes.count)
    }

    @Test("Exactly 64 nodes is accepted (boundary)")
    func maxNodeCountAccepted() throws {
        let nodes = (0..<EffectsPresetManager.maxImportNodeCount).map { _ in FXNodeConfig(kind: .gate) }
        let preset = EffectsPreset(isEnabled: true, nodes: nodes)
        let data = try #require(EffectsPresetManager.exportData(preset: preset))
        guard case .success = EffectsPresetManager.importData(data) else {
            Issue.record("expected success at the node-count boundary")
            return
        }
    }

    @Test("A pluginState over 2 MB on any node is rejected")
    func oversizedPluginStateRejected() throws {
        var node = FXNodeConfig(
            kind: .jsfx,
            pluginRef: FXPluginRef(format: .jsfx, identifier: "loopbacker:JSFX/x", name: "x", vendor: nil)
        )
        node.pluginState = Data(repeating: 0, count: EffectsPresetManager.maxImportPluginStateSize + 1)
        let preset = EffectsPreset(isEnabled: true, nodes: [FXNodeConfig(kind: .gate), node])
        let data = try #require(EffectsPresetManager.exportData(preset: preset))
        guard case .failure(.pluginStateTooLarge(let nodeIndex, let bytes)) = EffectsPresetManager.importData(data) else {
            Issue.record("expected .pluginStateTooLarge")
            return
        }
        #expect(nodeIndex == 1)
        #expect(bytes == node.pluginState?.count)
    }

    @Test("Garbage data that isn't valid JSON is rejected as invalid, not a crash")
    func invalidDataRejected() {
        let data = Data("not json".utf8)
        guard case .failure(.invalidData) = EffectsPresetManager.importData(data) else {
            Issue.record("expected .invalidData")
            return
        }
    }
}
