import Testing
import Foundation
@testable import Loopbacker

@Suite("MachOTextHasher")
struct MachOTextHasherTests {
    @Test("Hashing the same binary twice is deterministic")
    func deterministic() {
        let first = MachOTextHasher.textSectionDigest(ofExecutableAt: "/bin/cat")
        let second = MachOTextHasher.textSectionDigest(ofExecutableAt: "/bin/cat")
        #expect(first != nil)
        #expect(first == second)
    }

    @Test("Different binaries produce different digests")
    func differentBinariesDiffer() {
        let cat = MachOTextHasher.textSectionDigest(ofExecutableAt: "/bin/cat")
        let ls = MachOTextHasher.textSectionDigest(ofExecutableAt: "/bin/ls")
        #expect(cat != nil)
        #expect(ls != nil)
        #expect(cat != ls)
    }

    @Test("A non-Mach-O file returns nil instead of crashing")
    func nonMachOFileReturnsNil() {
        #expect(MachOTextHasher.textSectionDigest(ofExecutableAt: "/etc/hosts") == nil)
    }

    @Test("A missing file returns nil instead of crashing")
    func missingFileReturnsNil() {
        #expect(MachOTextHasher.textSectionDigest(ofExecutableAt: "/no/such/executable-\(UUID())") == nil)
    }
}
