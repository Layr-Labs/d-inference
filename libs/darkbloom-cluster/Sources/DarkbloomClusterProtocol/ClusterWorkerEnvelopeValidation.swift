import Foundation

/// Reuses the worker's strict integer/duplicate-key JSON scanner for its owning
/// transport envelope. This does not admit worker commands or native work.
public func validateClusterWorkerEnvelope(_ data: Data, commandStream: Bool) throws {
    let maximum = commandStream ? ClusterWorkerLimits.commandBytes : ClusterWorkerLimits.eventBytes
    guard !data.isEmpty, data.count <= maximum, data.last == 10,
          !data.dropLast().contains(10) else {
        throw ClusterWorkerProtocolError.invalid("Expected one bounded owner JSONL record")
    }
    try validateClusterWorkerJSON(data)
}
