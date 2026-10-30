import Foundation
import MachO
import CryptoKit

/// Extracts and hashes the `__TEXT,__text` section (the actual compiled code) of a Mach-O
/// executable, thin or fat. Unlike a whole-file hash or codesign's CDHash, this is unaffected by
/// re-signing with a different identity or by a fresh LC_UUID from recompiling unchanged source:
/// codesign only appends/replaces the signature in `__LINKEDIT` and never touches `__TEXT` page
/// bytes, and the UUID load command lives outside the `__TEXT` section's bytes.
enum MachOTextHasher {
    /// SHA-256 of the arm64 slice's `__TEXT,__text` bytes, or `nil` if `path` isn't a readable
    /// Mach-O containing that section (wrong format, no arm64 slice, stripped binary, etc).
    nonisolated static func textSectionDigest(ofExecutableAt path: String) -> Data? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let slice = thinSlice(in: data, matchingCPUType: UInt32(CPU_TYPE_ARM64)) else { return nil }
        guard let range = textSectionFileRange(in: slice),
              range.lowerBound >= 0, range.upperBound <= slice.count, range.lowerBound <= range.upperBound
        else { return nil }
        return Data(SHA256.hash(data: slice.subdata(in: range)))
    }

    /// Returns the arm64 slice of a fat (universal) binary, or `data` itself if it's already a
    /// thin 64-bit Mach-O of any architecture (the caller validates it's arm64 via the header).
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

    /// Walks the load commands of a thin 64-bit Mach-O to find `__TEXT,__text`'s file byte range.
    private static func textSectionFileRange(in slice: Data) -> Range<Int>? {
        guard slice.count >= MemoryLayout<mach_header_64>.size else { return nil }
        let header = slice.withUnsafeBytes { $0.loadUnaligned(as: mach_header_64.self) }
        guard header.magic == MH_MAGIC_64 else { return nil }

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

                if name(from: segment.segname) == "__TEXT" {
                    var sectionCursor = cursor + MemoryLayout<segment_command_64>.size
                    for _ in 0..<segment.nsects {
                        guard sectionCursor + MemoryLayout<section_64>.size <= slice.count else { return nil }
                        let section = slice.subdata(in: sectionCursor..<(sectionCursor + MemoryLayout<section_64>.size))
                            .withUnsafeBytes { $0.loadUnaligned(as: section_64.self) }
                        if name(from: section.sectname) == "__text" {
                            let start = Int(section.offset)
                            let size = Int(section.size)
                            guard size >= 0 else { return nil }
                            return start..<(start + size)
                        }
                        sectionCursor += MemoryLayout<section_64>.size
                    }
                }
            }
            cursor += Int(command.cmdsize)
        }
        return nil
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
