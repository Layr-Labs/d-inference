import Foundation
import IOKit

enum SystemControl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return cString(buffer)
    }

    static func cString(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    static func integer(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        // 32-bit sysctls fill only the low half.
        return size == MemoryLayout<Int32>.size ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }
}

enum RegistryProperty {
    static func value(_ entry: io_registry_entry_t, _ key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    /// Device-tree integers arrive as little-endian `Data`; service properties as numbers.
    static func integer(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        let raw = value(entry, key)
        if let number = raw as? NSNumber { return number.intValue }
        if let data = raw as? Data, data.count >= 4 {
            return Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        }
        return nil
    }

    static func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
        let raw = value(entry, key)
        if let string = raw as? String { return string }
        if let data = raw as? Data {
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            return text.isEmpty ? nil : text
        }
        return nil
    }

    static func name(_ entry: io_registry_entry_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return nil }
        return SystemControl.cString(buffer.map { UInt8(bitPattern: $0) })
    }

    static func matchingService(_ className: String) -> io_service_t? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        return service == IO_OBJECT_NULL ? nil : service
    }

    /// Calls `body` for each child of `parent` in `plane`; the child is released afterwards.
    static func forEachChild(
        of parent: io_registry_entry_t, plane: String, _ body: (io_registry_entry_t) -> Void
    ) -> Bool {
        var iterator = io_iterator_t()
        guard IORegistryEntryGetChildIterator(parent, plane, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }
        var child = IOIteratorNext(iterator)
        while child != IO_OBJECT_NULL {
            body(child)
            IOObjectRelease(child)
            child = IOIteratorNext(iterator)
        }
        return true
    }
}
