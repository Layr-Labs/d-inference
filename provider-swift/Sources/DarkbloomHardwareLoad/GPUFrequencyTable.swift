import Foundation
import IOKit

/// GPU DVFS table from the power manager (`pmgr` → `voltage-states9`), in MHz.
///
/// Entries are positional: IOReport's GPUPH states P1…P15 index this table in
/// order. It is not monotonic on every chip, so it must never be sorted.
enum GPUFrequencyTable {
    static func read() -> [Double] {
        var iterator = io_iterator_t()
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            guard RegistryProperty.name(entry) == "pmgr" else { continue }
            guard let data = RegistryProperty.value(entry, "voltage-states9") as? Data else { return [] }
            return frequenciesMHz(data)
        }
        return []
    }

    /// Decodes (frequency, voltage) UInt32 pairs, dropping zero frequencies.
    /// GPU tables store Hz; some generations store kHz, detected by magnitude.
    static func frequenciesMHz(_ data: Data) -> [Double] {
        var frequencies: [Double] = []
        data.withUnsafeBytes { raw in
            let words = raw.count / MemoryLayout<UInt32>.size
            for index in stride(from: 0, to: words - 1, by: 2) {
                let word = raw.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<UInt32>.size, as: UInt32.self)
                if word != 0 { frequencies.append(Double(word) / 1e6) }
            }
        }
        if let peak = frequencies.max(), peak < 100 { return frequencies.map { $0 * 1000 } }
        return frequencies
    }
}
