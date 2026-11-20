import Darwin
import Foundation
import Testing

/// Text a test passes through code under test without holding a copy of it:
/// the test keeps two random byte strings whose XOR is the text, and writes
/// the text only into buffers it zeroes itself. A scan of process memory then
/// finds the text only where the code under test left it.
struct UnheldText: Sendable {
    private let masked: [UInt8]
    private let mask: [UInt8]

    var count: Int { mask.count }

    /// `count` random lowercase letters.
    static func random(count: Int) -> UnheldText {
        var masked = [UInt8](repeating: 0, count: count)
        var mask = [UInt8](repeating: 0, count: count)
        var generator = SystemRandomNumberGenerator()
        for index in 0 ..< count {
            let key = UInt8.random(in: .min ... .max, using: &generator)
            masked[index] = UInt8.random(in: 0x61 ... 0x7a, using: &generator) ^ key
            mask[index] = key
        }
        return UnheldText(masked: masked, mask: mask)
    }

    func write(to destination: UnsafeMutableRawPointer) {
        for index in 0 ..< count {
            destination.storeBytes(of: masked[index] ^ mask[index], toByteOffset: index, as: UInt8.self)
        }
    }

    /// A strict part of the text as a `String`, so code under test can be
    /// handed the text in pieces that never hold all of it.
    func piece(_ range: Range<Int>) -> String {
        precondition(range.count < count && range.lowerBound >= 0 && range.upperBound <= count)
        var bytes = [UInt8](repeating: 0, count: range.count)
        for (offset, index) in range.enumerated() {
            bytes[offset] = masked[index] ^ mask[index]
        }
        defer { bytes.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Runs `body` on `prefix`, then the text and a space repeated until about
    /// `size` bytes, then `suffix`, in a buffer zeroed and freed afterwards.
    func withRepeated<R>(
        prefix: String, suffix: String, size: Int,
        _ body: (UnsafeMutableRawBufferPointer) throws -> R
    ) rethrows -> R {
        let head = Array(prefix.utf8)
        let tail = Array(suffix.utf8)
        let repeats = max(1, (size - head.count - tail.count) / (count + 1))
        let total = head.count + repeats * (count + 1) + tail.count
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: total, alignment: 16)
        defer {
            _ = memset_s(buffer.baseAddress, total, 0, total)
            buffer.deallocate()
        }
        buffer.copyBytes(from: head)
        var offset = head.count
        for _ in 0 ..< repeats {
            write(to: buffer.baseAddress! + offset)
            buffer[offset + count] = 0x20
            offset += count + 1
        }
        UnsafeMutableRawBufferPointer(rebasing: buffer[offset...]).copyBytes(from: tail)
        return try body(buffer)
    }
}

/// Copies of a text in this process's memory, read with
/// `mach_vm_read_overwrite` so an unmapped or protected range is reported
/// rather than faulted on. Only resident or swapped pages of readable regions
/// are read; the shared-cache submap is skipped. The needle and the read buffer
/// are VM allocations of their own whose addresses never count as a copy.
enum ProcessMemoryScan {
    struct Copy: Hashable, CustomStringConvertible {
        let address: mach_vm_address_t
        let userTag: UInt32
        var description: String { "0x\(String(address, radix: 16)) (tag \(userTag))" }
    }

    static func copies(of text: UnheldText) -> [Copy] {
        scan(for: text, stoppingAtFirst: false)
    }

    /// Whether any copy exists. This is the walk of `copies(of:)`, but it stops
    /// at the first copy and does not read the rest of the process.
    static func containsCopy(of text: UnheldText) -> Bool {
        !scan(for: text, stoppingAtFirst: true).isEmpty
    }

    private static func scan(for text: UnheldText, stoppingAtFirst: Bool) -> [Copy] {
        let task = mach_task_self_
        let bufferSize: mach_vm_size_t = 4 << 20
        let needleSize = mach_vm_size_t(getpagesize())
        var needleAddress: mach_vm_address_t = 0
        var bufferAddress: mach_vm_address_t = 0
        precondition(mach_vm_allocate(task, &needleAddress, needleSize, VM_FLAGS_ANYWHERE) == KERN_SUCCESS)
        precondition(mach_vm_allocate(task, &bufferAddress, bufferSize, VM_FLAGS_ANYWHERE) == KERN_SUCCESS)
        let needle = UnsafeMutableRawPointer(bitPattern: UInt(needleAddress))!
        let buffer = UnsafeMutableRawPointer(bitPattern: UInt(bufferAddress))!
        defer {
            _ = memset_s(needle, Int(needleSize), 0, Int(needleSize))
            _ = memset_s(buffer, Int(bufferSize), 0, Int(bufferSize))
            mach_vm_deallocate(task, needleAddress, needleSize)
            mach_vm_deallocate(task, bufferAddress, bufferSize)
        }
        text.write(to: needle)
        let ownRanges = [needleAddress ..< needleAddress + needleSize, bufferAddress ..< bufferAddress + bufferSize]
        let overlap = mach_vm_size_t(text.count - 1)

        var found = Set<Copy>()
        var address: mach_vm_address_t = 0
        while true {
            var size: mach_vm_size_t = 0
            var depth: natural_t = 0
            var info = vm_region_submap_info_data_64_t()
            var infoCount = mach_msg_type_number_t(
                MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<natural_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: Int32.self, capacity: Int(infoCount)) {
                    mach_vm_region_recurse(task, &address, &size, &depth, $0, &infoCount)
                }
            }
            guard status == KERN_SUCCESS else { break }
            defer { address += size }
            guard info.is_submap == 0, info.protection & VM_PROT_READ != 0,
                  info.pages_resident > 0 || info.pages_swapped_out > 0
            else { continue }
            var offset: mach_vm_size_t = 0
            while offset < size {
                let start = address + offset
                let length = min(bufferSize, size - offset)
                var copied: mach_vm_size_t = 0
                if mach_vm_read_overwrite(task, start, length, bufferAddress, &copied) == KERN_SUCCESS {
                    var cursor = 0
                    while Int(copied) - cursor >= text.count,
                          let match = memmem(buffer + cursor, Int(copied) - cursor, needle, text.count) {
                        let index = buffer.distance(to: match)
                        let hit = start + mach_vm_address_t(index)
                        if !ownRanges.contains(where: { $0.contains(hit) }) {
                            let copy = Copy(address: hit, userTag: info.user_tag)
                            if stoppingAtFirst { return [copy] }
                            found.insert(copy)
                        }
                        cursor = index + 1
                    }
                }
                if offset + length >= size { break }
                offset += length - overlap
            }
        }
        return found.sorted { $0.address < $1.address }
    }
}

extension ProcessMemoryScan {
    /// Records an issue when this process's memory still holds `text`.
    static func expectNoCopies(
        of text: UnheldText, after step: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let found = copies(of: text)
        if let first = found.first {
            Issue.record("\(found.count) copies in memory after \(step), first at \(first)",
                         sourceLocation: sourceLocation)
        }
    }
}
