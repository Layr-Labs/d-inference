import Foundation

/// Red control stub of #2437's member timeline: the same interface, and no line names anything.
struct NativePairOwnerTimeline: Sendable, Equatable {
    static let schema = "darkbloom-pair-owner-timeline-v1"
    var previousCancelled: UInt64?
    var previousFinished: UInt64?
    var prepareReceived: UInt64
    var prepared: UInt64?
    var committed: UInt64?
    var launchBegan: UInt64?
    var launched: UInt64?
    var firstReady: UInt64?

    init(prepareReceived: UInt64, previousCancelled: UInt64? = nil, previousFinished: UInt64? = nil) {
        self.prepareReceived = prepareReceived
        self.previousCancelled = previousCancelled; self.previousFinished = previousFinished
    }

    var durations: [(name: String, milliseconds: UInt64)] { [] }

    func line(epoch: UUID, generation: UInt64, rank: Int, modelID: String,
              dataPlane: (encrypted: Bool, peerVerified: Bool)?) -> String { "" }

    static let heartbeatSchema = "darkbloom-pair-session-heartbeat-v1"

    static func heartbeatLine(_ status: ClusterSessionStatus, sent: Bool, changedAt: UInt64, sentAt: UInt64,
                              committed: UInt64?) -> String { "" }

    static func uuidText(hex: String) -> String { "" }
}
