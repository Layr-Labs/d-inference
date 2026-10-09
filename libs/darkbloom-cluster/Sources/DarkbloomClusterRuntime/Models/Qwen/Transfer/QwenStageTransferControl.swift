import Foundation

enum QwenStageTransferRole: String { case sender, receiver }

/// What both ranks of one transfer hold in common: the load agreement (which
/// carries the membership epoch), the plan, and the pinned content record of
/// every planned tensor. The sender takes file and offset from a record; the
/// receiver takes the digest. Neither takes anything from its peer.
struct QwenStageTransferSession {
    let plan: QwenStageTransferPlan
    /// Plan order: `records[i]` is the pinned record of `plan.tensors[i]`.
    let records: [LayerStageTensorContentRecord]
    let fingerprint: String

    init(loadAgreementFingerprint: String, plan: QwenStageTransferPlan,
         inventory: LayerStageTensorContentInventory) throws {
        guard QwenDenseProfileIdentity.isSHA256(loadAgreementFingerprint) else {
            throw ProbeError("Stage transfer requires the load agreement's SHA-256")
        }
        let pinned = Dictionary(uniqueKeysWithValues: inventory.records.map { ($0.source.layout.canonicalName, $0) })
        records = try plan.tensors.map { tensor in
            // Equal shape and dtype fix the byte count: both sides validated it.
            guard let record = pinned[tensor.sourceName], record.source.layout.shape == tensor.shape,
                  record.source.layout.sourceDType == tensor.dtype.rawValue else {
                throw ProbeError("Stage transfer tensor differs from the pinned content inventory: \(tensor.sourceName)")
            }
            return record
        }
        self.plan = plan
        fingerprint = sha256(Data(["qwen-stage-transfer-session-v1", loadAgreementFingerprint,
            plan.fingerprint, inventory.encodedSHA256].joined(separator: "|").utf8))
    }
}

/// Fixed-size control values. Like a generation acknowledgement, a value is
/// the 64 characters of a digest as Int32. A rank compares what it received
/// with the values it computed itself; nothing received is ever parsed.
enum QwenStageTransferControl {
    enum Phase: String {
        case transferOpen
        case windowOpen, senderAbort
        case windowReceived, receiverAbort
        case stageVerified, stageRefused
        case senderComplete
    }

    static let valueCount = 64

    /// Bound to the session, the phase, the rank that says it, the window
    /// index and the cumulative payload bytes at that point.
    static func values(_ session: QwenStageTransferSession, _ phase: Phase, from role: QwenStageTransferRole,
                       window: Int, cumulativeBytes: Int) -> [Int32] {
        sha256(Data(["qwen-stage-transfer-control-v1", session.fingerprint, phase.rawValue, role.rawValue,
            String(window), String(cumulativeBytes)].joined(separator: "|").utf8)).utf8.map(Int32.init)
    }
}

/// The deadlines that end this rank abruptly, on its own uptime clock, and the
/// rule that keeps a transfer clear of them.
struct QwenStageTransferDeadlines {
    static let marginNanoseconds: UInt64 = 2_000_000_000

    let lifetimeUptimeNanoseconds: UInt64
    let startupUptimeNanoseconds: UInt64?
    /// The collective progress limit (`JACCL_PROGRESS_TIMEOUT_MS`): how long a
    /// survivor waits inside one native call for a peer that has died.
    let progressTimeoutNanoseconds: UInt64

    /// The transfer's own deadline, `start + budget`, or a refusal to begin.
    /// With the whole budget spent and one more call waiting out a dead peer,
    /// the rank must still fail by itself, on the path that releases memory,
    /// before either deadline ends it.
    func transferDeadline(start: UInt64, budgetNanoseconds: UInt64) throws -> UInt64 {
        // A sum past the end of the clock is past every deadline.
        func later(_ time: UInt64, by duration: UInt64) -> UInt64 {
            let sum = time.addingReportingOverflow(duration)
            return sum.overflow ? .max : sum.partialValue
        }
        let end = later(start, by: budgetNanoseconds)
        let cleared = later(later(end, by: progressTimeoutNanoseconds), by: Self.marginNanoseconds)
        guard cleared < lifetimeUptimeNanoseconds, startupUptimeNanoseconds.map({ cleared < $0 }) ?? true else {
            throw ProbeError("Stage transfer cannot finish before this rank's startup and lifetime deadlines")
        }
        return end
    }
}

/// The checks either end makes before every call, and its first local failure.
/// A failure noticed between calls does not stop the rank mid-window: the peer
/// is sending or expecting exactly the planned bytes, so the rank finishes the
/// window and says so at the next boundary. Cancellation and the lifetime
/// deadline are different: they stop it at once.
struct QwenStageTransferWatch {
    let deadlines: QwenStageTransferDeadlines
    /// The rank's uptime clock.
    let now: () -> UInt64
    /// `QwenResidentControl.check(deadline:)`.
    let check: (UInt64?) throws -> Void
    private(set) var transferDeadline: UInt64?
    private(set) var failure: (any Error)?

    init(deadlines: QwenStageTransferDeadlines, now: @escaping () -> UInt64,
         check: @escaping (UInt64?) throws -> Void) {
        self.deadlines = deadlines; self.now = now; self.check = check
    }

    /// The budget starts when the open exchange completes.
    mutating func begin(budgetNanoseconds: UInt64) {
        do { transferDeadline = try deadlines.transferDeadline(start: now(), budgetNanoseconds: budgetNanoseconds) }
        catch { fail(error) }
    }

    mutating func beforeCall() throws {
        try check(nil)
        guard failure == nil, let transferDeadline else { return }
        do { try check(transferDeadline) } catch { fail(ProbeError("Stage transfer exceeded its agreed duration")) }
    }

    /// Callers record a failure only while there is none: the first one is
    /// what the rank reports.
    mutating func fail(_ error: any Error) { failure = error }
}
