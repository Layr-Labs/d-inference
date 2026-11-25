import Foundation

/// When each step of one committed session happened on this member, on this
/// Mac's uptime clock (`DispatchTime`, never the wall clock), for the session's
/// one `darkbloom-pair-owner-timeline-v1` log line. A re-formed pair waited 15
/// to 19 s from its keys to its first call (drill 2026-11-20); with the
/// worker's own record (`darkbloom-owner-phases-v1`) this line splits that
/// wait. A record only: nothing reads it to make a decision. It carries the
/// session's epoch, generation, rank, model and durations, and no key.
struct NativePairOwnerTimeline: Sendable, Equatable {
    static let schema = "darkbloom-pair-owner-timeline-v1"
    /// The previous session of this member: when the coordinator's cancel of
    /// it arrived (a claim cancel after its home died, or any other) and when
    /// its run finished, that is when its old owner was seen stopped.
    var previousCancelled: UInt64?
    var previousFinished: UInt64?
    /// `native_pair_prepare` received.
    var prepareReceived: UInt64
    /// The installed files verified (`NativePairMemberInstallation.prepare`) and `prepared` decided.
    var prepared: UInt64?
    /// `native_pair_owner_start` (the commit) received.
    var committed: UInt64?
    /// The launch attempt began: the data-plane credential, then the owner's process.
    var launchBegan: UInt64?
    /// The owner's endpoint exists (its process started).
    var launched: UInt64?
    /// The first time this member saw its worker's readiness (`dataPlaneObservation`).
    var firstReady: UInt64?

    init(prepareReceived: UInt64, previousCancelled: UInt64? = nil, previousFinished: UInt64? = nil) {
        self.prepareReceived = prepareReceived
        self.previousCancelled = previousCancelled; self.previousFinished = previousFinished
    }

    /// Each step's duration in milliseconds, in order; a step that did not
    /// happen (or whose clock went backwards) is left out.
    var durations: [(name: String, milliseconds: UInt64)] {
        func span(_ name: String, _ from: UInt64?, _ to: UInt64?) -> (name: String, milliseconds: UInt64)? {
            guard let from, let to, to >= from else { return nil }
            return (name: name, milliseconds: (to - from) / 1_000_000)
        }
        return [
            span("cancel_to_prepare", previousCancelled, prepareReceived),
            span("old_owner_stopped_to_prepare", previousFinished, prepareReceived),
            span("prepare", prepareReceived, prepared),
            span("prepared_to_commit", prepared, committed),
            span("commit_to_launch", committed, launchBegan),
            span("launch", launchBegan, launched),
            span("launch_to_ready", launched, firstReady),
            span("commit_to_ready", committed, firstReady),
            span("cancel_to_ready", previousCancelled, firstReady),
        ].compactMap { $0 }
    }

    /// `ready`: whether the worker's readiness was seen; with it, whether its
    /// data plane was encrypted and its peer verified.
    func line(epoch: UUID, generation: UInt64, rank: Int, modelID: String,
              dataPlane: (encrypted: Bool, peerVerified: Bool)?) -> String {
        let ready = firstReady == nil ? "none" : "seen"
        let plane = dataPlane.map { " encrypted=\($0.encrypted ? 1 : 0) peer_verified=\($0.peerVerified ? 1 : 0)" } ?? ""
        let head = "\(Self.schema) epoch=\(epoch.uuidString.lowercased()) generation=\(generation) rank=\(rank)"
            + " model=\(modelID) ready=\(ready)" + plane
        return ([head] + durations.map { "\($0.name)_ms=\($0.milliseconds)" }).joined(separator: " ")
    }

    static let heartbeatSchema = "darkbloom-pair-session-heartbeat-v1"

    /// One line per event heartbeat a changed session report sent
    /// (`CoordinatorClient.adoptNativePairMember`): the report, whether a
    /// heartbeat could be written (`sent`), and the time from the change to the
    /// write and from the commit to the write. The one that reports
    /// `encrypted=1 peer_verified=1` is the one the coordinator admits the pair on.
    static func heartbeatLine(_ status: ClusterSessionStatus, sent: Bool, changedAt: UInt64, sentAt: UInt64,
                              committed: UInt64?) -> String {
        var fields: [String] = [heartbeatSchema, "epoch=\(uuidText(hex: status.epoch))", "generation=\(status.generation)",
                      "encrypted=\(status.encryptedDataPlane ? 1 : 0)", "peer_verified=\(status.peerVerified ? 1 : 0)",
                      "sent=\(sent ? 1 : 0)"]
        if sentAt >= changedAt { fields.append("change_to_send_ms=\((sentAt - changedAt) / 1_000_000)") }
        if let committed, sentAt >= committed { fields.append("commit_to_send_ms=\((sentAt - committed) / 1_000_000)") }
        return fields.joined(separator: " ")
    }

    /// A frame's 32-digit epoch as the UUID text the worker's and this
    /// member's other lines use; anything else unchanged.
    static func uuidText(hex: String) -> String {
        let digits = Array(hex)
        guard digits.count == 32 else { return hex }
        return [digits[0..<8], digits[8..<12], digits[12..<16], digits[16..<20], digits[20..<32]]
            .map { String($0) }.joined(separator: "-")
    }
}
