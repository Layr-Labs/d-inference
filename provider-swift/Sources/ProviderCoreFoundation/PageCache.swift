import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Drops a file's pages from the unified buffer cache after a bulk read.
///
/// `F_NOCACHE` keeps an aligned read from adding pages, but pages that are
/// already cached (just downloaded, or read earlier) stay cached and are read
/// from there. macOS has no `posix_fadvise`; `msync(MS_INVALIDATE)` over a
/// read-only shared mapping invalidates the file's resident pages (the method
/// `vmtouch -e` uses). Dirty pages are written back first, and any process
/// that maps the file faults its pages back in, so this frees memory without
/// changing file contents. Linux builds keep their cache.
public enum PageCache {
    /// Best effort: returns whether the resident pages were invalidated.
    @discardableResult
    public static func drop(fileAt url: URL) -> Bool {
        #if canImport(Darwin)
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return drop(descriptor: descriptor)
        #else
        return false
        #endif
    }

    #if canImport(Darwin)
    /// Same as `drop(fileAt:)` for a descriptor the caller already holds open.
    @discardableResult
    public static func drop(descriptor: Int32) -> Bool {
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { return false }
        guard value.st_size > 0, let length = Int(exactly: value.st_size) else { return value.st_size == 0 }
        guard let mapping = mmap(nil, length, PROT_READ, MAP_SHARED, descriptor, 0), mapping != MAP_FAILED
        else { return false }
        defer { munmap(mapping, length) }
        return msync(mapping, length, MS_INVALIDATE) == 0
    }

    /// Bytes of `url` resident in the unified buffer cache (`mincore`), or nil.
    public static func residentBytes(fileAt url: URL) -> UInt64? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { return nil }
        guard value.st_size > 0, let length = Int(exactly: value.st_size) else { return 0 }
        guard let mapping = mmap(nil, length, PROT_READ, MAP_SHARED, descriptor, 0), mapping != MAP_FAILED
        else { return nil }
        defer { munmap(mapping, length) }
        let pageSize = Int(getpagesize())
        var vector = [CChar](repeating: 0, count: (length + pageSize - 1) / pageSize)
        guard mincore(mapping, length, &vector) == 0 else { return nil }
        let pages = vector.reduce(0) { $0 + Int($1 & 1) }
        return UInt64(pages) * UInt64(pageSize)
    }
    #endif
}
