import Cmlx
import Foundation

/// The owner-authenticated JACCL bootstrap (PROD-PLAN S07): JACCL's side
/// channel (the four mesh rounds of queue-pair numbers, GIDs and two barrier
/// rounds) goes through this worker's owner over its PID-authenticated local
/// socket, and from there through both authenticated owners and the leader's
/// relay, instead of a TCP coordinator socket that JACCL would open on the
/// link itself (plaintext, unauthenticated, and the owner's oMLX lesson:
/// Thunderbolt bootstrap sockets stuck in SYN_SENT on a first launch).
///
/// Uses the pinned mlx-c bridge `mlx_distributed_init_jaccl_with_bootstrap`.
/// A worker that was started with the owner's attachment installs its exchange
/// here once, before loading; the one JACCL group of the process consumes it.
/// There is no fallback: `requireConsumedIfInstalled` stops a worker whose load
/// never used the installed exchange, and an installed exchange cannot be
/// replaced or reused.
public enum JACCLOwnerBootstrap {
    /// One round: (sequence, this rank's bytes) to both ranks' bytes in rank order.
    public typealias Exchange = @Sendable (UInt64, Data) throws -> Data

    private final class Slot: @unchecked Sendable {
        let lock = NSLock()
        var installed: (rank: Int, exchange: Exchange)?
        var consumed = false
        var everInstalled = false
    }
    private static let slot = Slot()

    /// Bytes per rank and in total; JACCL's mesh rounds are 4 and 64 bytes.
    static let maximumRankBytes = 65_536
    static let maximumTotalBytes = 131_072

    public static func install(rank: Int, exchange: @escaping Exchange) throws {
        guard (0...1).contains(rank) else { throw ProbeError("Owner bootstrap requires one of two ranks") }
        try slot.lock.withLock {
            guard !slot.everInstalled else { throw ProbeError("Owner bootstrap is installed once per worker process") }
            slot.installed = (rank, exchange); slot.everInstalled = true
        }
    }

    /// True once a worker installed an exchange (consumed or not).
    public static var isInstalled: Bool { slot.lock.withLock { slot.everInstalled } }

    /// After loading: an installed exchange must have created the group.
    public static func requireConsumedIfInstalled() throws {
        try slot.lock.withLock {
            guard !slot.everInstalled || slot.consumed else {
                throw ProbeError("The owner bootstrap was installed but the native group did not use it")
            }
        }
    }

    static func take() -> (rank: Int, exchange: Exchange)? {
        slot.lock.withLock {
            guard let value = slot.installed else { return nil }
            slot.installed = nil; slot.consumed = true
            return value
        }
    }

    /// Strict JACCL initialization through the owner's exchange. The C call
    /// consumes the context reference on every path.
    static func initialize(_ group: inout mlx_distributed_group, rank: Int, exchange: @escaping Exchange) -> Int32 {
        let context = Unmanaged.passRetained(BootstrapContext(rank: rank, exchange: exchange)).toOpaque()
        return mlx_distributed_init_jaccl_with_bootstrap(&group, Int32(rank), 2,
            maximumRankBytes, maximumTotalBytes, ownerBootstrapGather, context, ownerBootstrapRelease)
    }

    fileprivate final class BootstrapContext: @unchecked Sendable {
        let rank: Int
        let exchange: Exchange
        init(rank: Int, exchange: @escaping Exchange) { self.rank = rank; self.exchange = exchange }

        func gather(rank: Int, size: Int, sequence: UInt64, source: UnsafePointer<CChar>?, sourceBytes: Int,
                    destination: UnsafeMutablePointer<CChar>?, destinationBytes: Int) -> Int32 {
            guard rank == self.rank, size == 2, (1...JACCLOwnerBootstrap.maximumRankBytes).contains(sourceBytes),
                  destinationBytes == sourceBytes * 2, let source, let destination else { return 1 }
            do {
                let contribution = Data(bytes: source, count: sourceBytes)
                let result = Data(try exchange(sequence, contribution))
                guard result.count == destinationBytes,
                      result.subdata(in: rank * sourceBytes..<(rank + 1) * sourceBytes) == contribution else { return 1 }
                result.withUnsafeBytes { bytes in _ = memcpy(destination, bytes.baseAddress!, destinationBytes) }
                return 0
            } catch { return 1 }
        }
    }
}

private func ownerBootstrapGather(_ context: UnsafeMutableRawPointer?, _ rank: Int32, _ size: Int32,
                                  _ sequence: UInt64, _ source: UnsafePointer<CChar>?, _ sourceBytes: Int,
                                  _ destination: UnsafeMutablePointer<CChar>?, _ destinationBytes: Int) -> Int32 {
    guard let context else { return 1 }
    return Unmanaged<JACCLOwnerBootstrap.BootstrapContext>.fromOpaque(context).takeUnretainedValue().gather(
        rank: Int(rank), size: Int(size), sequence: sequence, source: source, sourceBytes: sourceBytes,
        destination: destination, destinationBytes: destinationBytes)
}

private func ownerBootstrapRelease(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<JACCLOwnerBootstrap.BootstrapContext>.fromOpaque(context).release()
}
