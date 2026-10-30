import Testing
import Foundation
@testable import Loopbacker

@Suite("MachOTextHasher")
struct MachOTextHasherTests {
    @Test("Hashing the same binary twice is deterministic")
    func deterministic() {
        let first = MachOTextHasher.contentDigest(ofExecutableAt: "/bin/cat")
        let second = MachOTextHasher.contentDigest(ofExecutableAt: "/bin/cat")
        #expect(first != nil)
        #expect(first == second)
    }

    @Test("Different binaries produce different digests")
    func differentBinariesDiffer() {
        let cat = MachOTextHasher.contentDigest(ofExecutableAt: "/bin/cat")
        let ls = MachOTextHasher.contentDigest(ofExecutableAt: "/bin/ls")
        #expect(cat != nil)
        #expect(ls != nil)
        #expect(cat != ls)
    }

    @Test("A non-Mach-O file returns nil instead of crashing")
    func nonMachOFileReturnsNil() {
        #expect(MachOTextHasher.contentDigest(ofExecutableAt: "/etc/hosts") == nil)
    }

    @Test("A missing file returns nil instead of crashing")
    func missingFileReturnsNil() {
        #expect(MachOTextHasher.contentDigest(ofExecutableAt: "/no/such/executable-\(UUID())") == nil)
    }

    @Test("A string-literal-only difference changes the digest")
    func stringLiteralDifferenceChangesDigest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceA = dir.appendingPathComponent("a.c")
        let sourceB = dir.appendingPathComponent("b.c")
        let dylibA = dir.appendingPathComponent("liba.dylib")
        let dylibB = dir.appendingPathComponent("libb.dylib")

        // Two tiny dylibs that differ only in a string literal -- no code changes, so this
        // exercises __TEXT,__cstring specifically, not __TEXT,__text.
        try "const char *label(void) { return \"version-one\"; }".write(to: sourceA, atomically: true, encoding: .utf8)
        try "const char *label(void) { return \"version-two\"; }".write(to: sourceB, atomically: true, encoding: .utf8)

        try compileDylib(source: sourceA, output: dylibA)
        try compileDylib(source: sourceB, output: dylibB)

        let digestA = MachOTextHasher.contentDigest(ofExecutableAt: dylibA.path)
        let digestB = MachOTextHasher.contentDigest(ofExecutableAt: dylibB.path)
        #expect(digestA != nil)
        #expect(digestB != nil)
        #expect(digestA != digestB)
    }

    @Test("The digest survives an independent ad-hoc re-sign")
    func digestSurvivesResigning() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("a.c")
        let dylib = dir.appendingPathComponent("lib.dylib")
        try "const char *label(void) { return \"same-content\"; }".write(to: source, atomically: true, encoding: .utf8)
        try compileDylib(source: source, output: dylib)

        let beforeResign = MachOTextHasher.contentDigest(ofExecutableAt: dylib.path)

        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", dylib.path]
        try codesign.run()
        codesign.waitUntilExit()
        #expect(codesign.terminationStatus == 0)

        let afterResign = MachOTextHasher.contentDigest(ofExecutableAt: dylib.path)
        #expect(beforeResign != nil)
        #expect(beforeResign == afterResign)
    }

    private func compileDylib(source: URL, output: URL) throws {
        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        clang.arguments = ["-dynamiclib", "-arch", "arm64", source.path, "-o", output.path]
        try clang.run()
        clang.waitUntilExit()
        #expect(clang.terminationStatus == 0)
    }
}
