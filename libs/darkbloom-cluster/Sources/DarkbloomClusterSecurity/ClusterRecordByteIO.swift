import Foundation

/// One immutable two-rank endpoint, exclusively used by one record adapter.
/// A successful call means actual native completion, NOT peer consumption.
/// Implementations must apply the supplied check around allocation/completion
/// and must never return partial receives. A blocking backend still requires an
/// independent process deadline; adapter invalidation does not interrupt it.
public protocol ClusterRecordByteIO: AnyObject {
    var localRank: Int { get }
    var worldSize: Int { get }
    var maximumFrameBytes: Int { get }
    func sendCompleted(_ bytes: Data, check: () throws -> Void) throws
    func receiveCompleted(byteCount: Int, check: () throws -> Void) throws -> Data
}

public struct ClusterRecordTransportStatus: Sendable, Equatable {
    public let active: Bool
    public let operationInFlight: Bool
    public let codec: ClusterRecordStatus

    /// The fields of the runtime's `darkbloom-data-plane-status-v1` line:
    /// counts and generations only, never key material. One rank's sealed
    /// figures equal its peer's opened figures when nothing was lost.
    public var lineFields: String {
        "active=\(active ? 1 : 0) sealed_records=\(codec.sealedRecords) opened_records=\(codec.openedRecords)"
            + " sealed_bytes=\(codec.sealedPlaintextBytes) opened_bytes=\(codec.openedPlaintextBytes)"
            + " send_generation=\(codec.sendGeneration) receive_generation=\(codec.receiveGeneration)"
    }
}
