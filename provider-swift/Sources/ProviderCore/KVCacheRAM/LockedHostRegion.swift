import Darwin
import Foundation

/// Anonymous memory for one RAM-only prefix-cache entry whose pages are wired
/// (`mlock`), so they are never written to the swap file. A forked child never
/// inherits them, and the kernel zeroes any page still wired when the mapping
/// is torn down (`MADV_ZERO_WIRED_PAGES`), so a process that dies without
/// releasing the region leaves nothing readable behind. `release` zeroes,
/// unlocks and unmaps it.
final class LockedHostRegion: @unchecked Sendable {
    typealias Wire = (UnsafeMutableRawPointer, Int) -> Int32

    let length: Int
    private let lock = NSLock()
    private var base: UnsafeMutableRawPointer?

    /// Nil when the pages can't be mapped or wired: the caller then keeps
    /// nothing, never an unwired copy.
    init?(bytes: Int, wire: Wire = { mlock($0, $1) }) {
        guard bytes > 0, let length = Self.pageRounded(bytes) else { return nil }
        guard let mapped = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
            mapped != MAP_FAILED
        else { return nil }
        guard madvise(mapped, length, MADV_ZERO_WIRED_PAGES) == 0,
            minherit(mapped, length, Int32(VM_INHERIT_NONE)) == 0,
            wire(mapped, length) == 0
        else {
            munmap(mapped, length)
            return nil
        }
        self.length = length
        self.base = mapped
    }

    deinit { release() }

    static func pageRounded(_ bytes: Int) -> Int? {
        let page = Int(getpagesize())
        let (padded, overflow) = bytes.addingReportingOverflow(page - 1)
        return overflow ? nil : padded / page * page
    }

    /// An eviction released the region while a copy was still using it.
    struct Released: Error {}

    func write(_ data: Data, at offset: Int) throws {
        try lock.withLock {
            guard let base else { throw Released() }
            precondition(offset >= 0 && data.count <= length - offset)
            data.withUnsafeBytes { source in
                guard let address = source.baseAddress else { return }
                base.advanced(by: offset).copyMemory(from: address, byteCount: source.count)
            }
        }
    }

    /// Runs `body` with a no-copy view of `count` bytes at `offset`; release
    /// waits for it. The view must not escape `body`.
    func withBytes<T>(at offset: Int, count: Int, _ body: (Data) throws -> T) throws -> T {
        try lock.withLock {
            guard let base else { throw Released() }
            precondition(offset >= 0 && count >= 0 && count <= length - offset)
            return try body(Data(bytesNoCopy: base.advanced(by: offset), count: count, deallocator: .none))
        }
    }

    func release() {
        lock.withLock {
            guard let base else { return }
            self.base = nil
            memset_s(base, length, 0, length)
            munlock(base, length)
            munmap(base, length)
        }
    }
}
