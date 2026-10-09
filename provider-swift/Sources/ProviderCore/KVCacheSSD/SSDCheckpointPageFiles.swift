import Darwin
import Foundation

/// Each checkpoint owns hard links to its immutable pages. Removing another
/// checkpoint's links cannot invalidate this endpoint, and the filesystem's
/// link count is the durable reference count after a crash.
enum SSDCheckpointPageFiles {
    static let directoryExtension = "pages"
    static let pageKind = "complete-checkpoint-page-v1"
    static let manifestKind = "complete-checkpoint-pages-v1"

    static func directory(for checkpoint: URL) -> URL {
        checkpoint.deletingPathExtension().appendingPathExtension(directoryExtension)
    }

    static func pageURL(checkpoint: URL, id: String) -> URL {
        SSDBlockStore.fileURL(root: directory(for: checkpoint), tag16Hex: String(id.prefix(32)))
    }

    struct File: Sendable {
        let url: URL
        let bytes: Int
        let device: Int32
        let inode: UInt64
        var physicalIdentity: String { "\(device):\(inode)" }
    }

    static func info(_ url: URL) -> File? {
        guard let handle = try? SSDNoFollowIO.openRegularFileForReading(at: url) else { return nil }
        defer { try? handle.close() }
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0,
            status.st_size >= 0, status.st_size <= Int.max else { return nil }
        return .init(url: url, bytes: Int(status.st_size), device: status.st_dev, inode: status.st_ino)
    }

    /// linkat operates on verified directories and never follows the source
    /// leaf. Authentication must validate the final link, since a previously
    /// authenticated source path could be replaced before linkat. A refused
    /// link is removed so the writer can encode the page anew.
    static func link(from source: URL, to destination: URL, strictFsync: Bool,
                     authenticate: (URL) throws -> Void) throws {
        try SSDNoFollowIO.prepareDirectory(destination.deletingLastPathComponent())
        let sourceFD = try SSDNoFollowIO.openDirectoryChain(source.deletingLastPathComponent())
        defer { Darwin.close(sourceFD) }
        let targetFD = try SSDNoFollowIO.openDirectoryChain(destination.deletingLastPathComponent())
        defer { Darwin.close(targetFD) }
        var before = stat()
        guard source.lastPathComponent.withCString({
            fstatat(sourceFD, $0, &before, AT_SYMLINK_NOFOLLOW)
        }) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
            throw SSDBlockStoreError.ioFailure("shared page is unavailable")
        }
        let result = source.lastPathComponent.withCString { sourceName in
            destination.lastPathComponent.withCString { targetName in
                linkat(sourceFD, sourceName, targetFD, targetName, 0)
            }
        }
        guard result == 0 else { throw SSDNoFollowIO.posixError("linkat page", url: destination) }
        var accepted = false
        defer {
            if !accepted { _ = destination.lastPathComponent.withCString { unlinkat(targetFD, $0, 0) } }
        }
        var after = stat()
        let inspected = destination.lastPathComponent.withCString {
            fstatat(targetFD, $0, &after, AT_SYMLINK_NOFOLLOW)
        }
        guard inspected == 0, (after.st_mode & S_IFMT) == S_IFREG,
            before.st_dev == after.st_dev, before.st_ino == after.st_ino else {
            throw SSDBlockStoreError.ioFailure("shared page changed during link")
        }
        try authenticate(destination)
        if strictFsync, fsync(targetFD) != 0 {
            throw SSDNoFollowIO.posixError("fsync page link", url: destination)
        }
        accepted = true
    }

    static func files(for checkpoint: URL) -> [File] {
        let root = directory(for: checkpoint)
        guard SSDBlockStore.isRealDirectory(root), SSDBlockStore.pathResolvesToItself(root),
            let fanouts = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var result: [File] = []
        for fanout in fanouts where SSDBlockStore.isLowerHex(fanout.lastPathComponent, count: 2) {
            guard SSDBlockStore.isRealDirectory(fanout), SSDBlockStore.pathResolvesToItself(fanout),
                let urls = try? FileManager.default.contentsOfDirectory(
                    at: fanout, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for url in urls where SSDBlockStore.isSafeBlockURL(url, modelRoot: root) {
                guard let file = info(url) else { continue }
                result.append(file)
            }
        }
        return result
    }

    static func physicalBytes(checkpoints: [URL]) -> Int {
        var objects: [String: Int] = [:]
        for checkpoint in checkpoints {
            if let file = info(checkpoint) {
                objects[file.physicalIdentity] = max(objects[file.physicalIdentity] ?? 0, file.bytes)
            }
            for file in files(for: checkpoint) {
                objects[file.physicalIdentity] = max(objects[file.physicalIdentity] ?? 0, file.bytes)
            }
        }
        return objects.values.reduce(0, saturatingAdd)
    }

    static func logicalBytes(checkpoint: URL, manifestBytes: Int) -> Int {
        files(for: checkpoint).reduce(manifestBytes) { saturatingAdd($0, $1.bytes) }
    }

    /// Delete only exact page files under this exact endpoint directory. Leaves
    /// outside the produced grammar, symlinks and foreign entries stay untouched.
    static func remove(for checkpoint: URL) {
        let root = directory(for: checkpoint)
        SSDBlockStore.sweepStaleTempFiles(under: root)
        for file in files(for: checkpoint) {
            _ = SSDBlockStore.removeItemIfSafe(at: file.url, under: root)
            removeEmptyDirectory(file.url.deletingLastPathComponent())
        }
        if let fanouts = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for fanout in fanouts where SSDBlockStore.isLowerHex(fanout.lastPathComponent, count: 2) {
                removeEmptyDirectory(fanout)
            }
        }
        removeEmptyDirectory(root)
    }

    /// Advisory discovery avoids entering destructive barriers for roots with
    /// no orphan endpoints. Removal still rechecks under the endpoint lease.
    static func hasOrphans(under modelRoot: URL) -> Bool {
        !orphanCheckpoints(under: modelRoot).isEmpty
    }

    static func removeOrphans(under modelRoot: URL) {
        for checkpoint in orphanCheckpoints(under: modelRoot) {
            guard let access = SSDCheckpointFileCoordinator.shared.tryAcquire(to: checkpoint) else { continue }
            defer { access.release() }
            if SSDBlockStore.indexedBlockFileStatus(at: checkpoint, under: modelRoot) == .missing {
                remove(for: checkpoint)
            }
        }
    }

    private static func orphanCheckpoints(under modelRoot: URL) -> [URL] {
        guard let fanouts = try? FileManager.default.contentsOfDirectory(
            at: modelRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for fanout in fanouts where SSDBlockStore.isLowerHex(fanout.lastPathComponent, count: 2) {
            guard SSDBlockStore.isRealDirectory(fanout), SSDBlockStore.pathResolvesToItself(fanout),
                let entries = try? FileManager.default.contentsOfDirectory(
                    at: fanout, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for directory in entries where directory.pathExtension == directoryExtension {
                let stem = directory.deletingPathExtension().lastPathComponent
                guard SSDBlockStore.isLowerHex(stem, count: 32), stem.hasPrefix(fanout.lastPathComponent),
                    SSDBlockStore.isRealDirectory(directory), SSDBlockStore.pathResolvesToItself(directory) else { continue }
                let checkpoint = SSDBlockStore.fileURL(root: modelRoot, tag16Hex: stem)
                if SSDBlockStore.indexedBlockFileStatus(at: checkpoint, under: modelRoot) == .missing {
                    result.append(checkpoint)
                }
            }
        }
        return result
    }

    static func synchronizeDirectories(for checkpoint: URL) throws {
        let root = directory(for: checkpoint)
        let fanouts = Set(files(for: checkpoint).map { $0.url.deletingLastPathComponent() })
        for directory in fanouts { try synchronize(directory) }
        try synchronize(root)
        try synchronize(checkpoint.deletingLastPathComponent())
    }

    static func synchronize(_ directory: URL) throws {
        let descriptor = try SSDNoFollowIO.openDirectoryChain(directory)
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw SSDNoFollowIO.posixError("fsync page directory", url: directory) }
    }

    static func removeEmptyDirectory(_ directory: URL) {
        guard let parent = try? SSDNoFollowIO.openDirectoryChain(directory.deletingLastPathComponent()) else { return }
        defer { Darwin.close(parent) }
        _ = directory.lastPathComponent.withCString { unlinkat(parent, $0, AT_REMOVEDIR) }
    }

    static func saturatingAdd(_ left: Int, _ right: Int) -> Int {
        let (sum, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int.max : sum
    }
}
