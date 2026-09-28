import DarkbloomClusterBootstrap
import Foundation

struct WorkerBootstrapConfiguration {
    static let names: Set<String> = ["--bootstrap-socket-path", "--bootstrap-owner-pid",
        "--bootstrap-deadline-uptime-nanoseconds"]
    let path: String
    let ownerProcessID: Int32
    let deadlineUptimeNanoseconds: UInt64

    static func parse(_ fields: [String: String], now: UInt64, lifetime: UInt64) throws -> Self? {
        let supplied = names.filter { fields[$0] != nil }
        if supplied.isEmpty { return nil } // Legacy experimental native TCP bootstrap.
        guard supplied.count == names.count, let path = fields["--bootstrap-socket-path"],
              path.hasPrefix("/"), path.utf8.count < 104, !path.contains("\0"),
              let pidText = fields["--bootstrap-owner-pid"], let pid = Int32(pidText),
              pid > 1, String(pid) == pidText,
              let deadlineText = fields["--bootstrap-deadline-uptime-nanoseconds"],
              let deadline = UInt64(deadlineText), String(deadline) == deadlineText,
              deadline > now, deadline <= lifetime else {
            throw WorkerFailure.invalid("Bootstrap requires the complete bounded local attachment")
        }
        return .init(path: path, ownerProcessID: pid, deadlineUptimeNanoseconds: deadline)
    }

    func connect(epoch: UUID, rank: Int, mode: ClusterBootstrapMode = .mesh2) throws -> ClusterBootstrapConnection {
        try .connect(path: path, ownerProcessID: ownerProcessID,
            identity: .init(membershipEpoch: epoch, rank: rank),
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds, mode: mode)
    }
}
