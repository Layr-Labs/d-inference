#if canImport(Darwin)
import Crypto
import Darwin
import Dispatch
import Foundation

/// SHA-256 of an open descriptor, read by a dedicated thread one chunk ahead
/// of the hash.
///
/// `F_NOCACHE` reads get no read-ahead, so a loop that reads and then hashes
/// leaves the device idle while it hashes and the CPU idle while it reads.
/// Two buffers alternate between the reader and the hashing caller, so both
/// stay busy. The digest is the same SHA-256 over the same bytes in order.
/// The reader is a dedicated thread, not pool work, because the caller blocks
/// on it and may itself be a pool thread.
final class OverlappedFileDigest: @unchecked Sendable {
    private let descriptor: Int32
    private let chunkBytes: Int
    private let buffers: [UnsafeMutableRawPointer]
    /// Bytes the reader placed in each buffer: 0 at end of file, -1 after a
    /// read error. Each slot is handed over through `filled` and `free`.
    private let lengths: UnsafeMutablePointer<Int>
    private let filled = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
    private let free = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
    private let readerExited = DispatchSemaphore(value: 0)

    /// nil when the descriptor cannot be read to its end.
    static func sha256(descriptor: Int32, chunkBytes: Int) -> SHA256Digest? {
        OverlappedFileDigest(descriptor: descriptor, chunkBytes: chunkBytes).run()
    }

    private init(descriptor: Int32, chunkBytes: Int) {
        self.descriptor = descriptor
        self.chunkBytes = chunkBytes
        let alignment = Int(getpagesize())
        buffers = (0..<2).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: chunkBytes, alignment: alignment)
        }
        lengths = .allocate(capacity: 2)
        lengths.initialize(repeating: 0, count: 2)
    }

    deinit {
        buffers.forEach { $0.deallocate() }
        lengths.deallocate()
    }

    private func run() -> SHA256Digest? {
        // Both buffers start free. They are signaled rather than created at 1:
        // the last read's slot is never handed back, and libdispatch traps when
        // a semaphore is deallocated below its initial value.
        free[0].signal()
        free[1].signal()
        let reader = Thread { [self] in readToEnd() }
        reader.qualityOfService = Thread.current.qualityOfService
        reader.start()
        // The reader stops after its last read, so the caller may close the
        // descriptor once this returns.
        defer { readerExited.wait() }
        var hasher = SHA256()
        var slot = 0
        while true {
            filled[slot].wait()
            let count = lengths[slot]
            guard count > 0 else { return count == 0 ? hasher.finalize() : nil }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffers[slot], count: count))
            free[slot].signal()
            slot ^= 1
        }
    }

    private func readToEnd() {
        defer { readerExited.signal() }
        var offset: off_t = 0
        var slot = 0
        while true {
            free[slot].wait()
            var count: Int
            repeat {
                count = pread(descriptor, buffers[slot], chunkBytes, offset)
            } while count < 0 && errno == EINTR
            lengths[slot] = count
            filled[slot].signal()
            guard count > 0 else { return }
            offset += off_t(count)
            slot ^= 1
        }
    }
}
#endif
