import Darwin
import Foundation

extension ModelDownloader {
    private static let cachePreparationLock = NSLock()

    /// Repair only a dangling per-model link, retaining the original link for
    /// recovery when its drive returns. Never replace a cache root, a regular
    /// file, or a link whose target is merely inaccessible.
    static func prepareModelCacheDirectory(at directory: URL) throws {
        try cachePreparationLock.withLock {
            let fm = FileManager.default
            let path = directory.path
            var entry = stat()
            if lstat(path, &entry) == 0 {
                if entry.st_mode & S_IFMT == S_IFLNK {
                    var target = stat()
                    if stat(path, &target) == 0 {
                        guard target.st_mode & S_IFMT == S_IFDIR else {
                            throw ModelCatalogError.downloadFailed("model cache link is not a directory: \(path)")
                        }
                        return
                    }
                    let code = errno
                    guard code == ENOENT else {
                        throw ModelCatalogError.downloadFailed(
                            "cannot access model cache link \(path): \(String(cString: strerror(code)))")
                    }

                    // Path-based operations avoid Foundation interpreting the
                    // dangling URL's directory hint as a request to follow it.
                    let backup = directory.deletingLastPathComponent().appendingPathComponent(
                        ".\(directory.lastPathComponent).unavailable-link-\(UUID().uuidString)")
                    try fm.moveItem(atPath: path, toPath: backup.path)
                } else {
                    guard entry.st_mode & S_IFMT == S_IFDIR else {
                        throw ModelCatalogError.downloadFailed("model cache path is not a directory: \(path)")
                    }
                    return
                }
            } else {
                let code = errno
                guard code == ENOENT else {
                    throw ModelCatalogError.downloadFailed(
                        "cannot access model cache path \(path): \(String(cString: strerror(code)))")
                }
            }

            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw ModelCatalogError.downloadFailed(
                    "cannot create model cache directory \(path); check the cache location and its drive: \(error.localizedDescription)")
            }
        }
    }
}
