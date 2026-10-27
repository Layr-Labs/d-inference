import Foundation

/// Fixed scalar chronology, charged to the existing 16 MiB host metadata
/// allowance. No tensors, resource observations, timer or native owner.
final class Gemma4MTPControlCounters {
    static let policy = "gemma4_remote_control_resource_boundaries_v1"
    enum Direction { case send, receive }
    enum Failure: Error { case failed, reentered, chronology, overflow }
    struct Snapshot: Encodable {
        let schema = "gemma4_remote_control_resource_counters_v1"
        let policy = Gemma4MTPControlCounters.policy
        let frameBytes = 16_384
        let sends: UInt64, receives: UInt64, completedOperations: UInt64
        let entryResourceChecks: UInt64, exitResourceChecks: UInt64, innerLifetimeChecks: UInt64
        let resourceValuesCachedAcrossOperations = false
        let snapshotResourceCadenceChanged = false, nativeCompletionFencesChanged = false
        let failed = false
    }
    private var sends: UInt64 = 0, receives: UInt64 = 0, completed: UInt64 = 0
    private var entries: UInt64 = 0, exits: UInt64 = 0, inner: UInt64 = 0
    private var active = false, failed = false, boundary = 0
    private func addingOne(_ value: UInt64) throws -> UInt64 {
        let (next, overflow) = value.addingReportingOverflow(1)
        guard !overflow else { poison(); throw Failure.overflow }
        return next
    }
    func begin(_ direction: Direction) throws {
        guard !failed else { throw Failure.failed }
        guard !active else { poison(); throw Failure.reentered }
        active = true; boundary = 0
        switch direction {
        case .send: sends = try addingOne(sends)
        case .receive: receives = try addingOne(receives)
        }
    }
    func resourceChecked() throws {
        guard !failed, active, boundary < 2 else { poison(); throw Failure.chronology }
        if boundary == 0 { entries = try addingOne(entries) }
        else { exits = try addingOne(exits) }
        boundary += 1
    }
    func innerChecked() throws {
        guard !failed, active, boundary == 1 else { poison(); throw Failure.chronology }
        inner = try addingOne(inner)
    }
    func complete() throws {
        guard !failed, active, boundary == 2 else { poison(); throw Failure.chronology }
        completed = try addingOne(completed); active = false
    }
    func poison() { failed = true }
    func snapshot() throws -> Snapshot {
        guard !failed, !active, completed == sends + receives, entries == completed, exits == completed else {
            throw Failure.chronology
        }
        return .init(sends:sends,receives:receives,completedOperations:completed,
            entryResourceChecks:entries,exitResourceChecks:exits,innerLifetimeChecks:inner)
    }
}
