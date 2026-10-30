import Testing
@testable import Loopbacker

/// A hosted plugin's reported parameter bounds are untrusted (AU v2/v3, JSFX via ysfx, which
/// doesn't validate `curve.min`/`curve.max`). `ClosedRange(lowerBound...upperBound)` traps when
/// `lowerBound > upperBound`, including when either bound is NaN. `FXParamSpec.safeRange` /
/// `.safeDefaultValue` (used by `HostedStageControls`, not `ClosedRange(spec.min...spec.max)`
/// directly) must never trap, regardless of what the plugin reports (LB-UI-001).
@Suite("FXParamSpec hosted-bounds safety")
struct FXParamSpecSafetyTests {
    private func spec(min: Float, max: Float, defaultValue: Float) -> FXParamSpec {
        FXParamSpec(id: "x", name: "X", detail: "", unit: .none, min: min, max: max, defaultValue: defaultValue)
    }

    @Test("Well-formed bounds pass through unchanged")
    func normalBoundsUnchanged() {
        let s = spec(min: 0, max: 10, defaultValue: 5)
        #expect(s.safeRange == 0...10)
        #expect(s.safeDefaultValue == 5)
    }

    @Test("Reversed bounds (min > max) are swapped, not trapped")
    func reversedBoundsSwapped() {
        let s = spec(min: 10, max: 0, defaultValue: 3)
        #expect(s.safeRange == 0...10)
        #expect(s.safeDefaultValue == 3)
    }

    @Test("NaN min falls back to 0...1")
    func nanMinFallsBack() {
        let s = spec(min: .nan, max: 10, defaultValue: 3)
        #expect(s.safeRange == 0...1)
    }

    @Test("NaN max falls back to 0...1")
    func nanMaxFallsBack() {
        let s = spec(min: 0, max: .nan, defaultValue: 3)
        #expect(s.safeRange == 0...1)
    }

    @Test("A NaN default value falls back to the range's lower bound")
    func nanDefaultFallsBackToLowerBound() {
        let s = spec(min: 2, max: 8, defaultValue: .nan)
        #expect(s.safeDefaultValue == 2)
    }

    @Test("A default value outside the (possibly swapped) range is clamped into it")
    func defaultValueClampedIntoRange() {
        let s = spec(min: 10, max: 0, defaultValue: 999)
        #expect(s.safeRange == 0...10)
        #expect(s.safeDefaultValue == 10)
    }

    @Test("Equal min and max (a degenerate but valid range) doesn't trap")
    func equalBoundsValid() {
        let s = spec(min: 5, max: 5, defaultValue: 5)
        #expect(s.safeRange == 5...5)
    }
}
