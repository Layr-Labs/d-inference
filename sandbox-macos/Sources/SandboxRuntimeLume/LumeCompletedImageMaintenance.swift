import Foundation
import HostRuntimeCoordination

/// Pure source-side proof used only beneath root's fresh ordinary EX lease.
/// Completed cleanup binds the original reservation/directory and the final disk
/// timestamps; no per-image fence may remain. Validation grants no offline IO.
final class LumeCompletedImageMaintenance {
    private let source: LumeBaseImageSourceLocks
    private let record: Data
    private let cleanup: LumeImageMaintenanceCleanup

    init(source: LumeBaseImageSourceLocks, intent: HostRuntimeMaintenanceIntent,
         cleanup: LumeImageMaintenanceCleanup) throws {
        self.source = source; self.cleanup = cleanup
        record = try LumeImageMaintenanceRecord(source: source, maintenance: intent).encoded()
    }

    func validate() throws {
        try source.validateIdentity()
        try LumeOfflineOperationFence.requireAbsent(directory: source.directoryDescriptor, name: source.baseSource.name)
        try cleanup.requireMatching(record: record, disk: source.currentDiskIdentityAfterOwnedIO())
    }
}
