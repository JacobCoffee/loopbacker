import Foundation
import MachO
import CryptoKit

/// Hashes the content of a Mach-O executable, thin or fat, in a way that survives re-signing.
/// Unlike a whole-file hash or codesign's CDHash, this is unaffected by a different signing
/// identity or by a fresh LC_UUID from recompiling unchanged source: codesign only
/// appends/replaces the signature in `__LINKEDIT` and never touches the bytes of any other
/// section, and the UUID load command isn't part of any section's bytes.
enum MachOTextHasher {
    /// SHA-256 over the raw file bytes of every section in every segment except `__LINKEDIT`
    /// (which holds nothing but the codesign signature, rewritten on every re-sign). Covers every
    /// kind of content change codesign never touches -- compiled code (`__TEXT,__text`), string
    /// literals (`__TEXT,__cstring`), constant tables (`__DATA_CONST,__const`), and so on -- not
    /// just the code section. Returns `nil` if `path` isn't a readable Mach-O with an arm64 slice
    /// containing at least one hashable section (wrong format, stripped binary, etc).
    nonisolated static func contentDigest(ofExecutableAt path: String) -> Data? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let slice = thinSlice(in: data, matchingCPUType: UInt32(CPU_TYPE_ARM64)) else { return nil }
        return sectionsDigest(in: slice)
    }

    /// Returns the arm64 slice of a fat (universal) binary, or `data` itself if it's already a
    /// thin 64-bit Mach-O matching `cpuType`.
    private static func thinSlice(in data: Data, matchingCPUType cpuType: UInt32) -> Data? {
        guard data.count >= MemoryLayout<UInt32>.size else { return nil }
        let magic = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }

        if magic == MH_MAGIC_64 {
            let header = data.withUnsafeBytes { $0.loadUnaligned(as: mach_header_64.self) }
            return header.cputype == cpuType ? data : nil
        }

        guard magic == FAT_MAGIC || magic == FAT_CIGAM else { return nil }
        guard data.count >= MemoryLayout<fat_header>.size else { return nil }
        let header = data.withUnsafeBytes { $0.loadUnaligned(as: fat_header.self) }
        let archCount = Int(header.nfat_arch.byteSwapped)
        let archesStart = MemoryLayout<fat_header>.size

        for index in 0..<archCount {
            let offset = archesStart + index * MemoryLayout<fat_arch>.size
            guard offset + MemoryLayout<fat_arch>.size <= data.count else { return nil }
            let arch = data.subdata(in: offset..<(offset + MemoryLayout<fat_arch>.size))
                .withUnsafeBytes { $0.loadUnaligned(as: fat_arch.self) }
            guard arch.cputype.byteSwapped == cpuType else { continue }
            let sliceOffset = Int(arch.offset.byteSwapped)
            let sliceSize = Int(arch.size.byteSwapped)
            guard sliceOffset >= 0, sliceSize >= 0, sliceOffset + sliceSize <= data.count else { return nil }
            return data.subdata(in: sliceOffset..<(sliceOffset + sliceSize))
        }
        return nil
    }

    /// Walks the load commands of a thin 64-bit Mach-O, hashing every section's file bytes from
    /// every segment except `__LINKEDIT`, in file order.
    private static func sectionsDigest(in slice: Data) -> Data? {
        guard slice.count >= MemoryLayout<mach_header_64>.size else { return nil }
        let header = slice.withUnsafeBytes { $0.loadUnaligned(as: mach_header_64.self) }
        guard header.magic == MH_MAGIC_64 else { return nil }

        var hasher = SHA256()
        var hashedAnySection = false
        var cursor = MemoryLayout<mach_header_64>.size

        for _ in 0..<header.ncmds {
            guard cursor + MemoryLayout<load_command>.size <= slice.count else { return nil }
            let command = slice.subdata(in: cursor..<(cursor + MemoryLayout<load_command>.size))
                .withUnsafeBytes { $0.loadUnaligned(as: load_command.self) }
            guard command.cmdsize > 0, cursor + Int(command.cmdsize) <= slice.count else { return nil }

            if command.cmd == UInt32(LC_SEGMENT_64),
               cursor + MemoryLayout<segment_command_64>.size <= slice.count {
                let segment = slice.subdata(in: cursor..<(cursor + MemoryLayout<segment_command_64>.size))
                    .withUnsafeBytes { $0.loadUnaligned(as: segment_command_64.self) }

                if name(from: segment.segname) != "__LINKEDIT" {
                    var sectionCursor = cursor + MemoryLayout<segment_command_64>.size
                    for _ in 0..<segment.nsects {
                        guard sectionCursor + MemoryLayout<section_64>.size <= slice.count else { return nil }
                        let section = slice.subdata(in: sectionCursor..<(sectionCursor + MemoryLayout<section_64>.size))
                            .withUnsafeBytes { $0.loadUnaligned(as: section_64.self) }

                        let start = Int(section.offset)
                        let size = Int(section.size)
                        let isZeroFill = (section.flags & UInt32(SECTION_TYPE)) == UInt32(S_ZEROFILL)
                        if size > 0, !isZeroFill, start >= 0, start + size <= slice.count {
                            hasher.update(data: slice.subdata(in: start..<(start + size)))
                            hashedAnySection = true
                        }
                        sectionCursor += MemoryLayout<section_64>.size
                    }
                }
            }
            cursor += Int(command.cmdsize)
        }

        guard hashedAnySection else { return nil }
        return Data(hasher.finalize())
    }

    /// `segname`/`sectname` are fixed 16-byte NUL-padded ASCII tuples in the Mach-O structs.
    private static func name(from raw: (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8)) -> String {
        withUnsafeBytes(of: raw) { buffer in
            let bytes = Data(buffer)
            let nul = bytes.firstIndex(of: 0) ?? bytes.endIndex
            return String(data: bytes[bytes.startIndex..<nul], encoding: .ascii) ?? ""
        }
    }
}
