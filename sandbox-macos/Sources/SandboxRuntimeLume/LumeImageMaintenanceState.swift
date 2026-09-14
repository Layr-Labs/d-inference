import Foundation
import HostRuntimeCoordination

/// Image half of the root transaction. The enclosing root scope owns machine
/// EX and the global fence throughout. Internal visibility permits owned IO
/// fixtures without giving unprivileged callers a root-authority bypass.
final class LumeImageMaintenanceState {
    private let source: LumeBaseImageSourceLocks
    private let store: LumeImageMaintenanceStore
    private let record: Data
    private var cleanup: LumeImageMaintenanceCleanup?
    private var completionStarted = false

    init(source: LumeBaseImageSourceLocks, intent: HostRuntimeMaintenanceIntent,
         recovering: Bool, cleanup: LumeImageMaintenanceCleanup? = nil) throws {
        self.source = source
        record = try LumeImageMaintenanceRecord(source: source, maintenance: intent).encoded()
        store = try LumeImageMaintenanceStore(source: source, expected: record)
        if let cleanup {
            guard recovering else { throw LumeImageMaintenanceError.changed }
            try cleanup.requireMatching(record: record, disk: source.currentDiskIdentityAfterOwnedIO())
            if try store.exists() { try store.pinMatching() }
            self.cleanup = cleanup; completionStarted = true
        } else if recovering, try store.exists() {
            // Authorized partial IO may have changed timestamps, but never the
            // reservation, original image identity, or bound directory inode.
            try store.pinMatching()
        } else {
            // The process may have exited after global publication but before
            // image publication. No image IO was authorized in that interval.
            try source.validateUnchanged()
            try store.publish()
        }
    }

    func validateForOfflineIO() throws {
        guard !completionStarted else { throw LumeImageMaintenanceError.completionStarted }
        try source.validateIdentity(); try store.validate()
    }

    func removeFenceAfterVerifiedCleanup(persist: (LumeImageMaintenanceCleanup) throws -> Void) throws {
        if !completionStarted { try validateForOfflineIO() }
        // Freeze IO even if persistence throws: the write may have reached disk.
        completionStarted = true
        let snapshot = try source.currentDiskIdentityAfterOwnedIO()
        let checkpoint = cleanup ?? LumeImageMaintenanceCleanup(record: record, disk: snapshot)
        try checkpoint.requireMatching(record: record, disk: snapshot)
        cleanup = checkpoint
        try persist(checkpoint)
        try checkpoint.requireMatching(record: record, disk: source.currentDiskIdentityAfterOwnedIO())
        try store.removeAfterRecordedCleanup()
        try checkpoint.requireMatching(record: record, disk: source.currentDiskIdentityAfterOwnedIO())
    }
}
