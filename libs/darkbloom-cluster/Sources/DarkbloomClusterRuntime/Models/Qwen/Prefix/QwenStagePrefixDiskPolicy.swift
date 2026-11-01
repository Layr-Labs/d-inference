import Foundation
#if canImport(DarkbloomClusterProtocol)
import DarkbloomClusterProtocol
#endif

/// The prompt-prefix tiers' decisions that need no model, no GPU and no disk:
/// which restore failure deletes a record, whose record a header is, and the
/// bounds derived from this Mac's memory and the plan's stop margin. Needs only
/// Foundation and `ClusterForcedExitBounds`, so a check compiles it alone.
public enum QwenStagePrefixDiskPolicy {
    /// A record file could not be opened or read for a reason that is not in
    /// its bytes (`errno`: interrupted, out of descriptors or memory, a busy or
    /// failing volume). The record may restore next time and is kept.
    public struct IOFailure: Error, CustomStringConvertible, Equatable {
        public let operation: String
        public let code: Int32
        public init(_ operation: String, code: Int32) { self.operation = operation; self.code = code }
        public var description: String { "Prefix record \(operation) failed (errno \(code))" }
    }

    /// Whether a failed restore deletes its record: only when the record
    /// itself failed (it did not authenticate, did not describe its file,
    /// belongs to another prompt or rank, or is gone), never for the request's
    /// own check (deadline, cancellation, a peer fault), an injected fault or
    /// an I/O failure the record is not to blame for.
    public static func deletesRecord(after error: Error, checkFailed: Bool, injected: Bool) -> Bool {
        if checkFailed || injected { return false }
        if let io = error as? IOFailure { return io.code == ENOENT }
        return true
    }

    /// A record restores only on the rank that wrote it: its sealed header
    /// names that rank. A record without one (written before the header named
    /// its rank) or naming another rank never restores here.
    public static func belongs(headerRank: Int?, to rank: Int) -> Bool { headerRank == rank }

    // MARK: Bounds derived from the Mac and the plan

    /// Host-visible bytes queued behind the SSD writer: a sixty-fourth of this
    /// Mac's memory (4 GiB on 256 GB, 1 GiB on 64 GB, 256 MiB on 16 GB), never
    /// below 256 MiB. A persist beyond it is dropped; serving never waits.
    public static func queuedBytesBound(physicalBytes: UInt64) -> Int {
        Int(clamping: max(UInt64(256) << 20, physicalBytes / 64))
    }

    /// The resident tier's ceiling: a thirty-second of this Mac's memory
    /// (8 GiB on 256 GB, 2 GiB on 64 GB), in whole 256 MiB steps (the
    /// budget's granule) and at least one. The budget is also never above half
    /// of the room the serving context leaves (`QwenStagePrefixCache.budget`).
    public static func residentCeilingBytes(physicalBytes: UInt64) -> Int {
        let granule = UInt64(256) << 20
        return Int(clamping: max(granule, physicalBytes / 32 / granule * granule))
    }

    /// The SSD tier's close before the model is released: the first bound,
    /// its one extension for a writer that is completing records, and the
    /// final drain of a write cut at its next unit. With the plan's stop
    /// margin (the time the owner gives a rank to give its memory back) all
    /// three fit in it: two fifths, two fifths, one fifth. Without one (a
    /// bench run outside an installed owner) the forced exit's dead-man is
    /// the margin's stand-in, as before: 20 s, 20 s and 5 s.
    public struct CloseBounds: Equatable, Sendable {
        public let boundSeconds: Double
        public let finalSeconds: Double
        public var longestSeconds: Double { 2 * boundSeconds + finalSeconds }
    }

    public static func closeBounds(stopMarginMilliseconds: Int?) -> CloseBounds {
        guard let margin = stopMarginMilliseconds, margin > 0 else {
            let deadMan = Double(ClusterForcedExitBounds.deadManNanoseconds) / 1e9
            return .init(boundSeconds: deadMan, finalSeconds: deadMan / 4)
        }
        let seconds = Double(margin) / 1000
        return .init(boundSeconds: seconds * 2 / 5, finalSeconds: seconds / 5)
    }
}
