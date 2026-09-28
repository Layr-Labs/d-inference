import DarkbloomClusterProtocol

/// Serial omission is required for legacy installed workers whose pinned
/// capability predates the optional CLI flag. Saved setup is still explicit.
enum DistributedInstalledPrefillSelection {
    static func workerArguments(capability: ClusterRuntimeCapability,
                                schedule: ClusterPrefillSchedule) throws -> [String] {
        try capability.requireSupport(for: schedule)
        return schedule == .serial ? [] : ["--prefill-schedule", schedule.rawValue]
    }
}
