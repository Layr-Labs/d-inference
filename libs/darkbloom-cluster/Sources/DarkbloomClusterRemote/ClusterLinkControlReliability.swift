import Foundation

/// Sender half of the reliable stream on one edge: every sequenced frame stays
/// here until the peer acknowledges it, and is retransmitted, in order, on the
/// next connection. Bounded in messages and bytes: a full outbox is
/// backpressure on the sender, never unbounded memory.
struct LinkOutbox: Sendable {
    struct Entry: Sendable, Equatable {
        let id: UInt64
        let kind: LinkFrameKind
        let body: Data
    }

    let maximumMessages: Int
    let maximumBytes: Int
    private(set) var nextID: UInt64 = 1
    private(set) var entries: [Entry] = []
    private var head = 0
    private(set) var bytes = 0

    init(maximumMessages: Int, maximumBytes: Int) {
        self.maximumMessages = maximumMessages; self.maximumBytes = maximumBytes
    }

    var count: Int { entries.count - head }
    var pending: ArraySlice<Entry> { entries[head...] }
    var highestAssigned: UInt64 { nextID - 1 }

    /// One message always fits into an empty outbox, whatever its size.
    func canAccept(bytes size: Int) -> Bool {
        count == 0 || (count < maximumMessages && bytes + size <= maximumBytes)
    }

    mutating func append(kind: LinkFrameKind, body: Data) -> UInt64 {
        let id = nextID
        nextID += 1
        entries.append(.init(id: id, kind: kind, body: body))
        bytes += body.count
        return id
    }

    /// Drops every entry at or below `through`. An acknowledgement of a message
    /// never sent is a protocol violation; an older one is harmless.
    @discardableResult
    mutating func acknowledge(through: UInt64) throws -> Int {
        guard through < nextID else { throw ClusterLinkControlError.protocolViolation }
        var removed = 0
        while head < entries.count, entries[head].id <= through {
            bytes -= entries[head].body.count
            head += 1; removed += 1
        }
        if head > 64, head * 2 > entries.count {
            entries.removeFirst(head); head = 0
        }
        return removed
    }

    /// The peer restarted: what was meant for its previous incarnation is gone.
    mutating func dropAll() -> Int {
        let dropped = count
        entries.removeAll(); head = 0; bytes = 0
        return dropped
    }
}

/// Receiver half: delivers each message ID once, in order. A new peer
/// incarnation starts a new stream at whatever ID it sends first; after that a
/// gap is a protocol violation and an old ID a retransmitted duplicate.
struct LinkInbox: Sendable, Equatable {
    enum Verdict: Equatable { case deliver, duplicate, gap }

    private(set) var expected: UInt64?

    var deliveredThrough: UInt64 { (expected ?? 1) - 1 }

    func verdict(for id: UInt64) -> Verdict {
        guard let expected else { return .deliver }
        if id < expected { return .duplicate }
        return id == expected ? .deliver : .gap
    }

    mutating func markDelivered(_ id: UInt64) { expected = id + 1 }

    mutating func startNewStream() { expected = nil }
}
