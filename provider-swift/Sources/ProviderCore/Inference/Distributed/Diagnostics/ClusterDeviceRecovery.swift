import Foundation
import DarkbloomClusterRemote

/// `darkbloom cluster recover`: explicit operator recovery of this Mac's
/// cluster device journal.
///
/// A journal outlives its owner only when the owner process ended before its
/// worker was seen to exit. Recovery clears it after proving, on this Mac, that
/// no process holds the device scope and that no running process carries the
/// recorded session's membership epoch. It refuses otherwise, changes nothing
/// when it refuses, and never signals a process.
public enum ClusterDeviceRecovery {
    public struct Report: Encodable, Sendable, Equatable {
        public enum Outcome: String, Encodable, Sendable {
            case nothingToRecover, cleared, refusedLiveOwner, refusedLiveWorker, refusedUnreadable
        }
        public struct Record: Encodable, Sendable, Equatable {
            public let clusterID: String
            public let peerID: String
            public let rank: Int
            public let membershipEpoch: String
        }
        public let schema = "darkbloom_cluster_recovery_v1"
        public let outcome: Outcome
        /// True when the device journal is empty after this command.
        public let journalEmpty: Bool
        public let recoveryPerformed: Bool
        public let record: Record?
        public let liveProcessIdentifier: Int32?
        public let detail: String
    }

    public static func recover() throws -> Report { try recover(paths: ClusterUserPaths()) }

    static func recover(paths: ClusterUserPaths) throws -> Report {
        report(try ClusterDeviceLeaseRecovery.recover(directoryURL: paths.deviceDirectory))
    }

    static func report(_ outcome: ClusterDeviceLeaseRecovery.Outcome) -> Report {
        func record(_ value: ClusterDeviceLeaseRecovery.Record) -> Report.Record {
            .init(clusterID: value.clusterID, peerID: value.peerID, rank: value.rank, membershipEpoch: value.membershipEpoch)
        }
        switch outcome {
        case .nothingToRecover:
            return .init(outcome: .nothingToRecover, journalEmpty: true, recoveryPerformed: false, record: nil,
                liveProcessIdentifier: nil, detail: "The device journal is absent or empty. Nothing was changed.")
        case .cleared(let value):
            return .init(outcome: .cleared, journalEmpty: true, recoveryPerformed: true, record: record(value),
                liveProcessIdentifier: nil,
                detail: "The journal named a session whose owner is gone. No process holds the device scope and none carries its membership epoch, so the journal was cleared.")
        case .refusedLiveOwner:
            return .init(outcome: .refusedLiveOwner, journalEmpty: false, recoveryPerformed: false, record: nil,
                liveProcessIdentifier: nil,
                detail: "A running process holds this Mac's device scope. An owner clears its own journal when its worker exits; wait for it, or stop the session on the leader. Nothing was changed.")
        case .refusedLiveWorker(let identifier, let value):
            return .init(outcome: .refusedLiveWorker, journalEmpty: false, recoveryPerformed: false, record: record(value),
                liveProcessIdentifier: identifier,
                detail: "Process \(identifier) still carries the recorded membership epoch: the worker this journal names is running. It ends itself at its own deadline. Nothing was changed.")
        case .refusedUnreadable:
            return .init(outcome: .refusedUnreadable, journalEmpty: false, recoveryPerformed: false, record: nil,
                liveProcessIdentifier: nil,
                detail: "The journal is not a record this build wrote, so nothing can be proven about what it names. Nothing was changed.")
        }
    }
}
