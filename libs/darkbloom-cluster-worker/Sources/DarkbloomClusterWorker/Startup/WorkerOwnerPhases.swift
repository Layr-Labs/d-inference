import DarkbloomClusterRuntime
import Foundation

/// Red control stub of #2437's worker start-up record: the same interface, and nothing is recorded.
final class WorkerOwnerPhases: @unchecked Sendable {
    static let schema = "darkbloom-owner-phases-v1"

    init(started: UInt64 = DispatchTime.now().uptimeNanoseconds) {}

    func mark(_ name: String, at now: UInt64 = DispatchTime.now().uptimeNanoseconds) {}

    func beginRuntime(_ totals: [ClusterLoadPhaseClock.Phase: ClusterLoadPhaseClock.Total] = ClusterLoadPhaseClock.totals,
                      at now: UInt64 = DispatchTime.now().uptimeNanoseconds) {}

    func endRuntime(_ totals: [ClusterLoadPhaseClock.Phase: ClusterLoadPhaseClock.Total] = ClusterLoadPhaseClock.totals,
                    at now: UInt64 = DispatchTime.now().uptimeNanoseconds) {}

    func ready(at now: UInt64 = DispatchTime.now().uptimeNanoseconds) {}

    var durations: [(name: String, milliseconds: UInt64)] { [] }

    var loadMemoryFields: String { "" }

    func line(rank: Int, epoch: UUID, generation: UInt64?, modelID: String, mode: String, stageCut: Int) -> String { "" }
}
