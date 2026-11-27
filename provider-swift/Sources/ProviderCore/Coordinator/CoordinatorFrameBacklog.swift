// Coordinator frames read but not yet handled: the limit that replaces TCP
// backpressure now that the link is read while a message is handled.

import Foundation

/// How much one coordinator connection may hold read but not yet handled
/// before the provider ends the link with close code 4003 (`inboundBacklog`).
///
/// Reading never waits on handling (`CoordinatorFrameReader`). A handler that
/// stops would otherwise let frames pile up in memory while each of them still
/// counts as liveness, so the link watch would never see the stall. The
/// coordinator admits at most 24 requests per provider at once, each frame at
/// most about 21.3 MiB, but a request it gives up on frees its slot while its
/// frame still waits here. Past a limit the link is ended rather than a frame
/// dropped, so the coordinator settles every request it had sent.
///
/// - `maxBytes`: the bytes of the frames read and not yet handled. Production:
///   768 MiB, 24 times the 32 MiB message limit.
/// - `maxFrames`: their number. Production: 4,096.
/// - `maxAge`: how long the oldest of them may wait for its handling to end,
///   counting a frame being handled. Production: 20 s, the link's dead bound,
///   so a handler stuck that long ends the link as a silent link would.
public struct CoordinatorInboundBacklog: Sendable, Equatable {
    public let maxBytes: Int
    public let maxFrames: Int
    public let maxAge: Duration

    /// Production uses the defaults; tests lower them.
    public init(maxBytes: Int = 768 * 1024 * 1024, maxFrames: Int = 4_096, maxAge: Duration = .seconds(20)) {
        precondition(maxBytes > 0 && maxFrames > 0 && maxAge > .zero, "an inbound backlog needs positive limits")
        self.maxBytes = maxBytes
        self.maxFrames = maxFrames
        self.maxAge = maxAge
    }
}

/// The limit a connection's backlog passed.
public enum CoordinatorBacklogExcess: Sendable, Equatable, CustomStringConvertible {
    case bytes(Int)
    case frames(Int)
    case age(Duration)

    public var description: String {
        switch self {
        case .bytes(let bytes): return "\(bytes) bytes read and not yet handled"
        case .frames(let frames): return "\(frames) frames read and not yet handled"
        case .age(let age): return "a frame waited \(age.components.seconds)s for its handling"
        }
    }
}

/// One connection's frames read and not yet handled, in read order. The reader
/// adds each frame before it hands it over; the receive loop removes it once
/// its handling has returned, so the frame being handled still counts.
final class CoordinatorFrameBacklog: @unchecked Sendable {
    let limits: CoordinatorInboundBacklog
    private let lock = NSLock()
    private var bytes = 0
    private var pending: [(size: Int, receivedAt: ContinuousClock.Instant)] = []
    /// A size limit, once passed, stays passed: the link is being ended.
    private var passed: CoordinatorBacklogExcess?

    init(limits: CoordinatorInboundBacklog) {
        self.limits = limits
    }

    /// Records a frame read. False once a size limit is passed: the reader then
    /// stops reading, and the ping task ends the link.
    func add(size: Int, receivedAt: ContinuousClock.Instant) -> Bool {
        lock.withLock {
            pending.append((size: size, receivedAt: receivedAt))
            bytes += size
            if passed == nil {
                if bytes > limits.maxBytes {
                    passed = .bytes(bytes)
                } else if pending.count > limits.maxFrames {
                    passed = .frames(pending.count)
                }
            }
            return passed == nil
        }
    }

    /// Forgets the oldest frame: its handling has returned.
    func finishOldest() {
        lock.withLock {
            guard !pending.isEmpty else { return }
            bytes -= pending.removeFirst().size
        }
    }

    /// The limit passed at `now`, if any.
    func excess(now: ContinuousClock.Instant) -> CoordinatorBacklogExcess? {
        lock.withLock {
            if let passed { return passed }
            // DO NOT MERGE: no age limit check.
            return nil
        }
    }
}
