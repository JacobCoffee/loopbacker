import Foundation
import Testing
@testable import Loopbacker

/// `soundboardChokeGroupTargets` is the pure decision `SoundboardPlayer.stopChokeGroup(of:)`
/// delegates to: given which items are currently playing (or still being decoded/prepared) and
/// their choke groups, which other items must stop. Exercised directly here rather than through
/// `SoundboardPlayer` itself, which needs real CoreAudio units to reach `activePlaybacks`.
@Suite("soundboardChokeGroupTargets")
struct SoundboardChokeGroupTests {
    private let triggered = UUID()
    private let activeSameGroup = UUID()
    private let activeOtherGroup = UUID()
    private let pendingSameGroup = UUID()
    private let pendingOtherGroup = UUID()

    @Test("No choke group on the triggered item stops nothing")
    func noGroupStopsNothing() {
        let targets = soundboardChokeGroupTargets(
            triggeredItemID: triggered, triggeredGroup: nil,
            activeGroups: [activeSameGroup: "reactions"], pendingGroups: [:]
        )
        #expect(targets.isEmpty)
    }

    @Test("An empty-string choke group stops nothing (same as no group)")
    func emptyGroupStopsNothing() {
        let targets = soundboardChokeGroupTargets(
            triggeredItemID: triggered, triggeredGroup: "",
            activeGroups: [activeSameGroup: ""], pendingGroups: [:]
        )
        #expect(targets.isEmpty)
    }

    @Test("An already-playing item sharing the group is a target")
    func activeItemInSameGroupIsTarget() {
        let targets = soundboardChokeGroupTargets(
            triggeredItemID: triggered, triggeredGroup: "reactions",
            activeGroups: [activeSameGroup: "reactions", activeOtherGroup: "stingers"], pendingGroups: [:]
        )
        #expect(targets == [activeSameGroup])
    }

    @Test("A still-starting (not yet active) item sharing the group is a target -- the regression this fixes")
    func pendingItemInSameGroupIsTarget() {
        // Before this fix, `stopChokeGroup` only scanned `activePlaybacks`, so an item whose
        // instance was still being decoded/prepared (not yet active) wasn't stopped, letting it
        // start playing alongside the new trigger despite sharing a choke group.
        let targets = soundboardChokeGroupTargets(
            triggeredItemID: triggered, triggeredGroup: "reactions",
            activeGroups: [:], pendingGroups: [pendingSameGroup: "reactions", pendingOtherGroup: "stingers"]
        )
        #expect(targets == [pendingSameGroup])
    }

    @Test("The triggered item itself is never its own target, even if listed")
    func triggeredItemExcludesItself() {
        let targets = soundboardChokeGroupTargets(
            triggeredItemID: triggered, triggeredGroup: "reactions",
            activeGroups: [triggered: "reactions"], pendingGroups: [triggered: "reactions"]
        )
        #expect(targets.isEmpty)
    }

    @Test("Active and pending targets in the same group are both returned, de-duplicated")
    func combinesActiveAndPendingTargets() {
        let targets = soundboardChokeGroupTargets(
            triggeredItemID: triggered, triggeredGroup: "reactions",
            activeGroups: [activeSameGroup: "reactions"], pendingGroups: [pendingSameGroup: "reactions"]
        )
        #expect(targets == [activeSameGroup, pendingSameGroup])
    }
}
