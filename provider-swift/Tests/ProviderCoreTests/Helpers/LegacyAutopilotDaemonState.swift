import Foundation
import ProviderCore

/// The relevant 0.9.15 reader contract: it knows the old optional key, but
/// applying convertFromSnakeCase breaks its explicit nested CodingKeys.
struct LegacyAutopilotDaemonState: Decodable {
    struct Snapshot: Decodable {
        let observeOnly: Bool
        enum CodingKeys: String, CodingKey { case observeOnly = "observe_only" }
    }
    let pid: Int32
    let version: String
    let writtenAt: Double
    let startedAt: Double
    let processIdentity: ProcessIdentity?
    let lifecycle: ProviderDrainStatus?
    let autopilot: Snapshot?

    func heartbeat() -> DaemonState {
        DaemonState(pid: pid, processIdentity: processIdentity, version: version,
            writtenAt: writtenAt, startedAt: startedAt, lifecycle: lifecycle)
    }
}
