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
}
