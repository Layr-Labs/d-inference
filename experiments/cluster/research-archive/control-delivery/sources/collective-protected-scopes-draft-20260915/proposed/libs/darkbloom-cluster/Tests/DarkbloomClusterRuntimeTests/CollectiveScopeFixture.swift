import CryptoKit
import DarkbloomClusterSecurity
import Foundation
@testable import DarkbloomClusterRuntime

/// In-memory completed byte IO only; no mock codec or native retirement claim.
final class CollectiveScopeFrames {
    var incoming: [[Data]] = [[], []]
    var sentCounts: [[Int]] = [[], []]
}
final class CollectiveScopeIO: ClusterRecordByteIO {
    let localRank: Int
    let worldSize = 2
    let maximumFrameBytes = 1064
    let frames: CollectiveScopeFrames
    var beforeSend: (() throws -> Void)?
    init(_ rank: Int, _ frames: CollectiveScopeFrames) { localRank = rank; self.frames = frames }
    func sendCompleted(_ bytes: Data, check: () throws -> Void) throws {
        try check(); try beforeSend?()
        frames.incoming[1 - localRank].append(bytes)
        frames.sentCounts[localRank].append(bytes.count); try check()
    }
    func receiveCompleted(byteCount: Int, check: () throws -> Void) throws -> Data {
        try check()
        guard let first = frames.incoming[localRank].first, first.count == byteCount else {
            throw ProbeError("Scope fixture lacks its exact completed frame")
        }
        frames.incoming[localRank].removeFirst(); try check(); return first
    }
}
struct CollectiveScopePair {
    let frames: CollectiveScopeFrames
    let binding: ClusterRecordBinding
    let first: ClusterAuthenticatedRecordTransport
    let second: ClusterAuthenticatedRecordTransport
    let firstIO: CollectiveScopeIO
    init() throws {
        let frames = CollectiveScopeFrames(); self.frames = frames
        binding = try .init(epoch: UUID(uuidString: "d01cf2aa-3306-4699-ab39-f050da5d187c")!,
            planSHA256: Data(repeating: 0x21, count: 32), membershipTranscriptSHA256: Data(repeating: 0x42, count: 32))
        firstIO = .init(0, frames)
        let key = SymmetricKey(data: Data(repeating: 0x63, count: 32)) // public test key
        let limits = try ClusterRecordLimits(maximumPlaintextBytes: 1024)
        first = try .init(sessionKey: key, binding: binding, limits: limits, io: firstIO)
        second = try .init(sessionKey: key, binding: binding, limits: limits, io: CollectiveScopeIO(1, frames))
    }
    func request(_ id: String = "6012e020-9a4e-473d-9316-96990a17d411") throws -> CollectiveRequestScope {
        try .init(requestID: UUID(uuidString: id)!, epoch: binding.epoch,
            planSHA256: String(repeating: "21", count: 32), agreementSHA256: String(repeating: "31", count: 32))
    }
    func expectation(_ scope: CollectiveOperationScope, count: Int = 8) throws -> ClusterRecordTransferExpectation {
        try scope.requireBinding(binding)
        return try .init(context: scope.context, length: .exact(count))
    }
}
