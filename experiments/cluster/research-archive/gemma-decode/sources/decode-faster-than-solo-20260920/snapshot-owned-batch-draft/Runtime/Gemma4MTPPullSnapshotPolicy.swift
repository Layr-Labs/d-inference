import Foundation

/// Explicit private experiment. Absence preserves all existing wire/scope bytes.
enum Gemma4MTPPullSnapshotPolicy: String {
    case perTensor = "gemma4_snapshot_per_tensor_v1"
    case ownedBatch = "gemma4_owned_snapshot_batch_gpu_boundaries_v1"
    static let batchObservationPolicy = "gemma4_remote_control_boundaries_owned_snapshot_v1"
    init(requested: String?) throws {
        if let requested {
            guard requested == Self.ownedBatch.rawValue else {
                throw Failure("Unsupported explicit snapshot transfer policy")
            }
            self = .ownedBatch
        } else { self = .perTensor }
    }
    var scopeComponents: [String] { self == .perTensor ? [] : ["snapshotPolicy="+rawValue] }
    struct Failure: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
}

/// Scalar accounting for exactly seven ordered native transfers. Completion is
/// set only after both actual boundary statuses and all seven CPU completions.
/// It is not a release authority: roots remain with the original owner/ACK.
struct Gemma4MTPPullSnapshotBatchProgress {
    enum Phase: Equatable { case fresh, preparing, transferring, complete, failed }
    private(set) var phase: Phase = .fresh
    private(set) var retained = 0, completed = 0, boundaries = 0
    mutating func begin() throws {
        guard phase == .fresh else { throw failure() }
        phase = .preparing
    }
    mutating func preparedAfterFence() throws {
        guard phase == .preparing, retained == 0, completed == 0, boundaries == 0 else { throw failure() }
        boundaries = 1; phase = .transferring
    }
    func requireNext(_ index: Int) throws {
        guard phase == .transferring, (0..<7).contains(index), retained == index, completed == index else { throw failure() }
    }
    mutating func outputRetained(_ index: Int) throws {
        try requireNext(index); retained += 1
    }
    mutating func transferCompleted(_ index: Int) throws {
        guard phase == .transferring, (0..<7).contains(index), retained == index+1, completed == index else { throw failure() }
        completed += 1
    }
    mutating func finishAfterFence() throws {
        guard phase == .transferring, retained == 7, completed == 7, boundaries == 1 else { throw failure() }
        boundaries = 2; phase = .complete
    }
    mutating func poison() { phase = .failed }
    private func failure() -> Gemma4MTPPullSnapshotPolicy.Failure {
        .init("Owned snapshot batch state/count differs; completion cannot authorize reuse")
    }
}
