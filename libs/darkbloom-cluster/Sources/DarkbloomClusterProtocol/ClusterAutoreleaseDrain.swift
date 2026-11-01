import Foundation

/// The cluster's control loops (owner writer and reader, worker owner, relays, service ticks) run on threads and dispatch
/// queues whose blocks never return, so the autorelease pool a run loop or a finished work item would drain is never
/// drained: every Foundation object such a loop autoreleases (JSONSerialization's writer, its 4 KB output buffer, parsed
/// dictionaries and strings) lives as long as the process. Rank 0 and its worker owner grew about 20 MiB a minute under
/// load that way (round 6c case 5). Work done once per token, record or tick runs inside `drained`, which empties its own
/// pool before it returns; what the body returns is retained by the Swift value it is bridged to.
public enum ClusterAutorelease {
    @inline(__always)
    public static func drained<T>(_ body: () throws -> T) rethrows -> T {
        #if canImport(ObjectiveC)
        return try autoreleasepool(invoking: body)
        #else
        return try body()
        #endif
    }
}
