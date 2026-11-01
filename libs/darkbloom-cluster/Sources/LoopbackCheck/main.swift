import CryptoKit
import Foundation
import MLX
import DarkbloomClusterRuntime
import DarkbloomClusterSecurity

// Collective transport discovery + contract check, single process. This
// build (macOS 14 minimum, matching the provider) has NO distributed
// backend: Darkbloom's pinned mlx-swift excludes ring/mpi/nccl and compiles
// the JACCL stub below a 26.2 deployment target. This check pins the
// fail-closed behavior (no silent singleton fallback) and the pure
// transport contracts. Real collective execution requires the separate
// macOS 26.2 worker plus authorized Thunderbolt hardware — recorded as
// blocked, never simulated.

enum CheckError: Error { case failed(String) }
func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw CheckError.failed(message) }
}
func reject(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch is CheckError { throw CheckError.failed(message) } catch { return }
    throw CheckError.failed(message)
}

@main enum TransportContractCheck {
    static func main() throws {
        try backendDiscovery()
        try pointToPointShapeContract()
        try tokenAgreementContract()
        try recordByteIOBounds()
        print(#"{"passed":true,"groups":4,"collectiveExecution":"blocked-no-backend-in-this-build","rdma":false}"#)
    }

    static func backendDiscovery() throws {
        // Discovery only, never inferred support: the pinned build's JACCL
        // availability is reported, and the excluded ring backend must be
        // refused WITHOUT a singleton fallback.
        let jaccl = Collective.jacclAvailable
        print(#"{"discovery":{"jacclAvailable":\#(jaccl)}}"#)
        try reject("loopback backend admitted without its backend") {
            _ = try Collective(transport: .loopbackTest)
        }
        // A loopback init without MLX_RANK/MLX_HOSTFILE is refused before any
        // backend work even when a backend exists.
        try reject("jaccl group created in a single-process check") {
            _ = try Collective(transport: .jaccl)
        }
    }

    static func pointToPointShapeContract() throws {
        let shape = try CollectivePointToPointShape(shape: [2, 4], dtype: .float32, maximumBytes: 64)
        try require(shape.elements == 8 && shape.byteCount == 32, "shape accounting differs")
        // Exact metadata validation against a real array.
        let array = MLXArray((0..<8).map { Float($0) }, [2, 4])
        try shape.validateMetadata(array)
        try reject("wrong dtype admitted") { try shape.validateMetadata(MLXArray([Int32](0..<8), [2, 4])) }
        try reject("wrong shape admitted") { try shape.validateMetadata(MLXArray((0..<8).map { Float($0) }, [8])) }
        // Closed bounds: dtype set, dimensions, hard limits, overflow.
        try reject("unsupported dtype admitted") { _ = try CollectivePointToPointShape(shape: [2], dtype: .float64, maximumBytes: 64) }
        try reject("too many dimensions admitted") { _ = try CollectivePointToPointShape(shape: [1, 1, 1, 1, 1], dtype: .float32, maximumBytes: 64) }
        try reject("zero dimension admitted") { _ = try CollectivePointToPointShape(shape: [0], dtype: .float32, maximumBytes: 64) }
        try reject("over-limit transfer admitted") { _ = try CollectivePointToPointShape(shape: [128], dtype: .float32, maximumBytes: 64) }
        try reject("unbounded limit admitted") { _ = try CollectivePointToPointShape(shape: [1], dtype: .float32, maximumBytes: 0) }
    }

    static func tokenAgreementContract() throws {
        var state = TokenSelectionSequence(sequence: 7, vocabularySize: 32, outputCount: 4)
        let payload = state.payload(localArgmax: 9, sequence: 7, step: 0, rank: 0)
        // A valid rank-0 payload carries the exact tag/sequence/step/bounds.
        try require(payload == [73, 7, 0, 32, 4, 9, 1], "token payload contract changed")
        // Rank 1 never contributes a token but must agree on metadata.
        let peer = state.payload(localArgmax: 9, sequence: 7, step: 0, rank: 1)
        try require(peer == [73, 7, 0, 32, 4, 0, 1], "peer payload contract changed")
        // The combined sum is accepted in step order and advances.
        let token = try state.accept([146, 14, 0, 64, 8, 9, 2], sequence: 7, step: 0)
        try require(token == 9, "token agreement selected the wrong token")
        // Stale sequence, wrong step, tag mismatch, out-of-vocabulary token
        // and disagreement are all refused.
        try reject("stale sequence admitted") { _ = try state.accept([146, 16, 0, 64, 8, 9, 2], sequence: 8, step: 1) }
        try reject("tag substitution admitted") { _ = try state.accept([145, 14, 0, 64, 8, 9, 2], sequence: 7, step: 1) }
        try reject("out-of-vocabulary token admitted") { _ = try state.accept([146, 14, 2, 64, 8, 32, 2], sequence: 7, step: 1) }
        try reject("rank disagreement admitted") { _ = try state.accept([146, 14, 2, 64, 8, 9, 1], sequence: 7, step: 1) }
        // Invalid local metadata is zeroed into the collective so BOTH ranks reject.
        let bad = TokenSelectionSequence(sequence: 7, vocabularySize: 32, outputCount: 4)
        let invalid = bad.payload(localArgmax: 99, sequence: 8, step: 3, rank: 0)
        try require(invalid == [73, 8, 3, 32, 4, 0, 0], "invalid metadata not carried for bilateral rejection")
    }

    static func recordByteIOBounds() throws {
        // The encrypted record byte IO requires a real two-rank collective;
        // its shape/bounds contract is checked at the point-to-point layer
        // above. Here: the authenticated record transport over a synthetic
        // in-memory byte IO still pins the encrypted-frame contract the
        // collective adapter consumes.
        let io = LoopbackRecordIO(rank: 0, maximumFrameBytes: 4136)
        let binding = try ClusterRecordBinding(epoch: UUID(),
            planSHA256: Data(repeating: 1, count: 32),
            membershipTranscriptSHA256: Data(repeating: 2, count: 32))
        let limits = try ClusterRecordLimits(maximumPlaintextBytes: 4096,
            maximumRecordsPerDirection: 16, maximumCumulativePlaintextBytesPerDirection: 65_536)
        _ = try ClusterAuthenticatedRecordTransport(sessionKey: SymmetricKey(size: .bits256),
            binding: binding, limits: limits, io: io)
        try reject("wrong-rank byte IO admitted") {
            _ = try ClusterAuthenticatedRecordTransport(sessionKey: SymmetricKey(size: .bits256),
                binding: binding, limits: limits, io: LoopbackRecordIO(rank: 2, maximumFrameBytes: 4136))
        }
    }
}

/// Synthetic in-memory record byte IO for contract checks; not a collective.
final class LoopbackRecordIO: ClusterRecordByteIO, @unchecked Sendable {
    let localRank: Int
    let worldSize = 2
    let maximumFrameBytes: Int
    init(rank: Int, maximumFrameBytes: Int) { localRank = rank; self.maximumFrameBytes = maximumFrameBytes }
    func sendCompleted(_ bytes: Data, check: () throws -> Void) throws {}
    func receiveCompleted(byteCount: Int, check: () throws -> Void) throws -> Data { Data(count: byteCount) }
}
