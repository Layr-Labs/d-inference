import CryptoKit
import DarkbloomClusterSecurity
import Foundation
import MLX

/// The keyed data plane of one Collective (S16). Every array a rank sends to
/// its peer leaves as one or more authenticated, encrypted records of the
/// record transport (AES-256-GCM, directional keys, rekeyed by count, bytes
/// and age) and is reconstructed only after every record opened. The keys come
/// from the pinned exchange (`ClusterDataPlaneKeyExchange`); this type never
/// sees them. Any failure poisons the transport: there is no plaintext retry.
public final class CollectiveAuthenticatedRecords {
    /// One record's plaintext at most; larger arrays are carried in chunks.
    public static let chunkBytes = 8 * 1024 * 1024
    private let bytes: CollectiveRecordByteIO
    private let records: ClusterAuthenticatedRecordTransport

    /// The transport a confirmed key exchange made over `io`.
    init(transport: ClusterAuthenticatedRecordTransport, io: CollectiveRecordByteIO) throws {
        guard transport.localRank == io.localRank, transport.maximumFrameBytes == io.maximumFrameBytes else {
            throw ProbeError("Keyed data plane differs from its byte endpoint")
        }
        bytes = io; records = transport
    }

    public var status: ClusterRecordTransportStatus { records.status }
    public func invalidate() { records.invalidate() }
    public func maximumNativeFrameAllocation(for length: ClusterRecordTransferLength) throws -> Int {
        try bytes.maximumNativeFrameAllocation(for: length)
    }

    /// Native dtype bytes unchanged; shape, dtype, chunk index and length are
    /// bound in each record's authenticated data with the caller's scope.
    func sendArray(_ input: MLXArray, scope: CollectiveRecordScope, maximumBytes: Int,
                   check: () throws -> Void) throws {
        do {
            func checked() throws {
                try check()
                guard records.status.active else { throw ClusterRecordTransferError.inactive }
            }
            let geometry = try CollectivePointToPointShape.authenticatedArray(shape: input.shape, dtype: input.dtype,
                maximumBytes: maximumBytes)
            try geometry.validateMetadata(input)
            try checked()
            let plaintext = try CollectivePointToPoint.copyCompletedBytes(input,
                geometry: geometry, check: checked)
            let chunks = Self.chunks(geometry.byteCount, size: min(Self.chunkBytes, records.maximumPlaintextBytes))
            for (index, range) in chunks.enumerated() {
                let expectation = try scope.expectation(shape: geometry.shape, dtype: geometry.dtype,
                    chunk: index, of: chunks.count, length: range.count)
                let base = plaintext.startIndex
                try records.send(chunks.count == 1 ? plaintext
                        : plaintext.subdata(in: (base + range.lowerBound)..<(base + range.upperBound)),
                    expecting: expectation, check: checked)
            }
            try checked()
        } catch { records.invalidate(); throw error }
    }

    /// Every record authenticates and the post-open check passes before the
    /// native array is constructed. The caller keeps its own semantic checks.
    func receiveArray(shape: [Int], dtype: DType, scope: CollectiveRecordScope, maximumBytes: Int,
                      check: () throws -> Void) throws -> MLXArray {
        do {
            func checked() throws {
                try check()
                guard records.status.active else { throw ClusterRecordTransferError.inactive }
            }
            try checked()
            let geometry = try CollectivePointToPointShape.authenticatedArray(shape: shape, dtype: dtype, maximumBytes: maximumBytes)
            let chunks = Self.chunks(geometry.byteCount, size: min(Self.chunkBytes, records.maximumPlaintextBytes))
            var plaintext = Data()
            if chunks.count > 1 { plaintext.reserveCapacity(geometry.byteCount) }
            for (index, range) in chunks.enumerated() {
                let expectation = try scope.expectation(shape: geometry.shape, dtype: geometry.dtype,
                    chunk: index, of: chunks.count, length: range.count)
                let part = try records.receive(expecting: expectation, check: checked)
                guard part.count == range.count else { throw ClusterRecordTransferError.unexpectedByteCount }
                if chunks.count == 1 { plaintext = part } else { plaintext.append(part) }
            }
            try checked()
            let array = try CollectivePointToPoint.materializeCompletedBytes(plaintext,
                geometry: geometry, check: checked)
            try checked()
            return array
        } catch { records.invalidate(); throw error }
    }

    static func chunks(_ count: Int, size: Int) -> [Range<Int>] {
        stride(from: 0, to: count, by: size).map { $0..<min(count, $0 + size) }
    }
}
