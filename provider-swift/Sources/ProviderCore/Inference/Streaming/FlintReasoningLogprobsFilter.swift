// Copyright © 2026 Eigen Labs.

/// Relay logprobs for an exact-Flint request whose reasoning is withheld.
/// Logprobs cover every sampled token and the relay attaches pending entries
/// to the next content frame, so without this filter the hidden thought would
/// reach the client as entry tokens. Flint reasons only in an optional initial
/// `<think>…</think>` span, and the first close ends it
/// (``FlintNativeProtocolBoundary``). Entries are matched on their bytes, so a
/// marker assembled from ordinary tokens is recognized too. Every entry of the
/// span is dropped, including the ones that open or complete a marker.
struct FlintReasoningLogprobsFilter: Sendable {
    private static let open = Array("<think>".utf8)
    private static let close = Array("</think>".utf8)

    private enum Phase: Sendable { case undecided, thought, visible }
    private var phase = Phase.undecided
    /// Entries that may still spell the opening marker.
    private var held: [SSETokenLogprob] = []
    /// Undecided prefix, or the bounded thought tail searched for the close.
    private var tail: [UInt8] = []

    /// The entries the client may receive. Entries still undecided at the end
    /// of a stream are never released.
    mutating func visible(_ entries: [SSETokenLogprob]) -> [SSETokenLogprob] {
        var out: [SSETokenLogprob] = []
        for entry in entries {
            switch phase {
            case .visible:
                out.append(entry)
            case .undecided:
                held.append(entry)
                tail += Self.bytes(entry)
                if tail.starts(with: Self.open) {
                    held = []
                    tail.removeFirst(Self.open.count)
                    phase = .thought
                    closeIfComplete()
                } else if !Self.open.starts(with: tail) {
                    out += held
                    held = []
                    tail = []
                    phase = .visible
                }
            case .thought:
                tail += Self.bytes(entry)
                closeIfComplete()
            }
        }
        return out
    }

    private mutating func closeIfComplete() {
        let width = Self.close.count
        if tail.count >= width,
           (0...(tail.count - width)).contains(where: { tail[$0..<($0 + width)].elementsEqual(Self.close) }) {
            tail = []
            phase = .visible
        } else if tail.count >= width {
            tail.removeFirst(tail.count - (width - 1))
        }
    }

    private static func bytes(_ entry: SSETokenLogprob) -> [UInt8] {
        entry.bytes.map { $0.map { UInt8(truncatingIfNeeded: $0) } } ?? Array(entry.token.utf8)
    }
}
