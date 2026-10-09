import Foundation

/// Restore cost counts every page read; disk pressure counts each inode once.
/// Keep this distinction in the RAM index so heartbeat/budget snapshots never
/// traverse the filesystem or accidentally charge hard links twice.
final class SSDCheckpointPageAccounting: @unchecked Sendable {
    private struct Object: Hashable { let device: Int32; let inode: UInt64 }
    private struct Entry { let logicalBytes: Int; let objects: [Object] }
    private struct Held { var bytes: Int; var references: Int }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var objects: [Object: Held] = [:]
    private var logicalBytes = 0
    private var physicalBytes = 0

    func register(checkpoint: URL) {
        let path = SSDCheckpointFileCoordinator.pathKey(for: checkpoint)
        guard let main = SSDCheckpointPageFiles.info(checkpoint) else { return }
        let files = [main] + SSDCheckpointPageFiles.files(for: checkpoint)
        let logical = files.reduce(0) { SSDCheckpointPageFiles.saturatingAdd($0, $1.bytes) }
        lock.withLock {
            let indexedLogical = entries[path]?.logicalBytes ?? logical
            removeLocked(path)
            var ids: [Object] = []
            for file in files {
                let id = Object(device: file.device, inode: file.inode)
                ids.append(id)
                if var held = objects[id] {
                    // An external mutation can grow a shared inode between
                    // observations. Retain the largest observed size until its
                    // final link retires, rather than undercharging survivors.
                    if file.bytes > held.bytes {
                        physicalBytes = SSDCheckpointPageFiles.saturatingAdd(physicalBytes, file.bytes - held.bytes)
                        held.bytes = file.bytes
                    }
                    held.references += 1
                    objects[id] = held
                } else {
                    objects[id] = Held(bytes: file.bytes, references: 1)
                    physicalBytes = SSDCheckpointPageFiles.saturatingAdd(physicalBytes, file.bytes)
                }
            }
            entries[path] = Entry(logicalBytes: indexedLogical, objects: ids)
            logicalBytes = SSDCheckpointPageFiles.saturatingAdd(logicalBytes, indexedLogical)
        }
    }

    func reconcile(indexedCheckpoints: [URL]) {
        let paths = Set(indexedCheckpoints.map(SSDCheckpointFileCoordinator.pathKey))
        lock.withLock {
            for path in Array(entries.keys) where !paths.contains(path) { removeLocked(path) }
        }
        for checkpoint in indexedCheckpoints {
            let known = lock.withLock { entries[SSDCheckpointFileCoordinator.pathKey(for: checkpoint)] != nil }
            if known || SSDBlockStore.isRealDirectory(SSDCheckpointPageFiles.directory(for: checkpoint)) {
                register(checkpoint: checkpoint)
            }
        }
    }

    /// Bytes uniquely owned by this retained endpoint. Shared objects become
    /// reclaimable only after their other indexed endpoint links retire.
    /// Ranking reads cached metadata only; it never stats or decrypts files.
    func marginalReclaimableBytes(checkpoint: URL) -> Int? {
        let path = SSDCheckpointFileCoordinator.pathKey(for: checkpoint)
        return lock.withLock {
            guard let entry = entries[path] else { return nil }
            var ownReferences: [Object: Int] = [:]
            for object in entry.objects { ownReferences[object, default: 0] += 1 }
            return ownReferences.reduce(0) { bytes, item in
                guard let held = objects[item.key], held.references == item.value else { return bytes }
                return SSDCheckpointPageFiles.saturatingAdd(bytes, held.bytes)
            }
        }
    }

    func remove(checkpoint: URL) {
        let path = SSDCheckpointFileCoordinator.pathKey(for: checkpoint)
        lock.withLock { removeLocked(path) }
    }
    func removeAll() { lock.withLock { entries.removeAll(); objects.removeAll(); logicalBytes = 0; physicalBytes = 0 } }
    func diskBytes(indexedBytes: Int) -> Int {
        lock.withLock { SSDCheckpointPageFiles.saturatingAdd(max(0, indexedBytes - logicalBytes), physicalBytes) }
    }

    private func removeLocked(_ path: String) {
        guard let entry = entries.removeValue(forKey: path) else { return }
        logicalBytes = max(0, logicalBytes - entry.logicalBytes)
        for object in entry.objects {
            guard var held = objects[object] else { continue }
            held.references -= 1
            if held.references > 0 { objects[object] = held }
            else { objects.removeValue(forKey: object); physicalBytes = max(0, physicalBytes - held.bytes) }
        }
    }
}
