import Cmlx
import Foundation

/// Internal bridge for an already owned local channel. The exchange closure must
/// authenticate/validate its owner route and enforce a local bootstrap deadline.
final class JACCLBootstrap: @unchecked Sendable {
    typealias Exchange = @Sendable (UUID, Int, Int, UInt64, Data, Int) throws -> Data
    let membershipEpoch: UUID
    let rank: Int
    private let exchange: Exchange
    private let lock = NSLock()
    private var attempted = false

    init(membershipEpoch: UUID, rank: Int, exchange: @escaping Exchange) throws {
        guard (0...1).contains(rank) else { throw BootstrapError.invalid }
        self.membershipEpoch = membershipEpoch
        self.rank = rank
        self.exchange = exchange
    }

    func initialize(_ group: inout mlx_distributed_group) throws -> Int32 {
        try lock.withLock {
            guard !attempted else { throw BootstrapError.reused }
            attempted = true
        }
        // C consumes this reference on success and failure. The backend cache
        // may retain it until process exit; group-handle free is not a fence.
        let context = Unmanaged.passRetained(self).toOpaque()
        return mlx_distributed_init_jaccl_with_bootstrap(&group, Int32(rank), 2,
            65_536, 131_072, bootstrapGather, context, bootstrapRelease)
    }

    fileprivate func gather(rank: Int, size: Int, sequence: UInt64,
                            source: UnsafePointer<CChar>?, sourceBytes: Int,
                            destination: UnsafeMutablePointer<CChar>?, destinationBytes: Int) -> Int32 {
        guard rank == self.rank, size == 2, (1...65_536).contains(sourceBytes),
              destinationBytes == sourceBytes * 2, let source, let destination else { return 1 }
        do {
            let contribution = Data(bytes: source, count: sourceBytes)
            let result = try exchange(membershipEpoch, rank, size, sequence, contribution, destinationBytes)
            guard result.count == destinationBytes else { return 1 }
            result.withUnsafeBytes { bytes in
                _ = memcpy(destination, bytes.baseAddress!, destinationBytes)
            }
            return 0
        } catch { return 1 }
    }

    enum BootstrapError: Error { case invalid, reused }
}

private func bootstrapGather(_ context: UnsafeMutableRawPointer?, _ rank: Int32, _ size: Int32,
                             _ sequence: UInt64, _ source: UnsafePointer<CChar>?, _ sourceBytes: Int,
                             _ destination: UnsafeMutablePointer<CChar>?, _ destinationBytes: Int) -> Int32 {
    guard let context else { return 1 }
    return Unmanaged<JACCLBootstrap>.fromOpaque(context).takeUnretainedValue().gather(
        rank: Int(rank), size: Int(size), sequence: sequence, source: source, sourceBytes: sourceBytes,
        destination: destination, destinationBytes: destinationBytes)
}

private func bootstrapRelease(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<JACCLBootstrap>.fromOpaque(context).release()
}
