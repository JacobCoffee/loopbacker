import Testing
@testable import Loopbacker

@Suite("DriverInstaller version comparison")
struct DriverInstallerTests {
    @Test("A higher minor or patch component is newer")
    func higherComponentIsNewer() {
        #expect(DriverInstaller.isVersion("0.2.0", newerThan: "0.1.0"))
        #expect(DriverInstaller.isVersion("0.1.1", newerThan: "0.1.0"))
        #expect(DriverInstaller.isVersion("1.0.0", newerThan: "0.9.9"))
    }

    @Test("Equal versions are not newer")
    func equalVersionsAreNotNewer() {
        #expect(!DriverInstaller.isVersion("0.1.0", newerThan: "0.1.0"))
    }

    @Test("A lower version is not newer")
    func lowerVersionIsNotNewer() {
        #expect(!DriverInstaller.isVersion("0.1.0", newerThan: "0.2.0"))
        #expect(!DriverInstaller.isVersion("0.9.9", newerThan: "1.0.0"))
    }

    @Test("Missing trailing components count as zero")
    func missingComponentsCountAsZero() {
        #expect(DriverInstaller.isVersion("0.2", newerThan: "0.1.9"))
        #expect(!DriverInstaller.isVersion("0.1", newerThan: "0.1.0"))
        #expect(DriverInstaller.isVersion("0.1.1", newerThan: "0.1"))
    }

    @Test("Non-numeric components don't crash and are treated as zero")
    func nonNumericComponentsAreZero() {
        #expect(!DriverInstaller.isVersion("abc", newerThan: "0.0.1"))
        #expect(DriverInstaller.isVersion("0.0.1", newerThan: "abc"))
    }
}
