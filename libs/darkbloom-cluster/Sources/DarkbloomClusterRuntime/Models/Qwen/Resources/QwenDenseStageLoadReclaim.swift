import Darwin
import Foundation

/// Turns file cache the kernel can drop into free pages, by the kernel's own policy: anonymous memory is touched a
/// chunk at a time and released at once. The gate counts only the file cache the kernel takes before applications'
/// memory (`QwenDenseStageLoadPolicy`), which on a 36 GB M4 Max in use was 1.3 of 14.5 GB: a part that fit was refused
/// at load and at every request, and touching 4 to 6 GB dropped that much cache with the compressor unchanged
/// (2026-10-16). Stops at the first sign of harm: more compressions or swap-outs than `harmBytes`, or pressure above
/// normal. Nothing is kept; the caller samples again and the gate decides on that sample.
enum QwenDenseStageLoadReclaim {
    static let chunkBytes = 128 << 20
    static let harmBytes = 64 << 20
    /// Never asked for more than this in one attempt.
    static let maximumBytes = 8 << 30

    /// Bytes touched (and released) before it stopped; 0 when nothing could be judged or touched.
    @discardableResult
    static func makeRoom(bytes: Int, observe: () throws -> QwenDenseStageLoadOSObservation = QwenDenseStageLoadResources.observeOS) -> Int {
        guard bytes > 0, let start = try? observe(), start.pressureLevel <= QwenDenseStageLoadPolicy.normalPressureLevel else { return 0 }
        let page = max(start.pageSizeBytes, 4096)
        var chunks: [(UnsafeMutableRawPointer, Int)] = []
        defer { for (pointer, length) in chunks { munmap(pointer, length) } }
        var touched = 0
        while touched < min(bytes, maximumBytes) {
            guard let pointer = mmap(nil, chunkBytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
                  pointer != MAP_FAILED else { break }
            chunks.append((pointer, chunkBytes))
            var offset = 0
            while offset < chunkBytes { pointer.storeBytes(of: 1, toByteOffset: offset, as: UInt8.self); offset += page }
            touched += chunkBytes
            guard let now = try? observe(), now.pressureLevel <= QwenDenseStageLoadPolicy.normalPressureLevel,
                  (now.compressionPages - start.compressionPages) * page <= harmBytes,
                  (now.swapoutPages - start.swapoutPages) * page <= harmBytes else { break }
        }
        return touched
    }
}
