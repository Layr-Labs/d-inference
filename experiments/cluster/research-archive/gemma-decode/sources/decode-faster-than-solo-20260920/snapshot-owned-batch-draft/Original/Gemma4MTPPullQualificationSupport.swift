import Foundation
import MLX

/// A single terminal fixture retention slot, never a reusable native owner.
final class Gemma4MTPPullQualificationRoots {
    var group: Collective?
    var capture: Gemma4OwnedMTPConditioning?
    var staging: Gemma4MTPPullReceiveStaging?
    var batch: MLXArray?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var failed: Gemma4MTPPullQualificationRoots?
    static func requireAvailable() throws {
        lock.lock(); defer { lock.unlock() }
        guard failed == nil else { throw ProbeError("Failed pull qualifier cannot run again") }
    }
    func retainFailure() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        precondition(Self.failed == nil || Self.failed === self)
        Self.failed = self
    }
    func releaseCompleted(check: () throws -> Void) throws {
        try Gemma4MTPPullNativeFence.join(check:check)
        capture = nil; batch = nil; staging?.installedAfterFence(); staging = nil
        try Gemma4MTPPullNativeFence.join(check:check)
    }
}

enum Gemma4MTPPullQualificationSupport {
    typealias Record = Gemma4MTPPullRecord
    static let labels = ["seven-roots-queued-fenced-pull-finish", "queued-work-cancelled-after-fence",
        "post-receive-check-failure-retains-roots", "stale-sequence-refused", "nonzero-padding-refused"]
    static func require(_ value: Bool, _ message: String) throws { guard value else { throw ProbeError(message) } }
    static func capture(frontier: Int, check: () throws -> Void) throws -> Gemma4OwnedMTPConditioning {
        try check()
        // Integer-valued BF16 roots give an independent exact comparison after
        // the actual seven transfers, including full-head concatenations.
        return .init(frontier:frontier,hidden:MLXArray.ones([1,1,2816],dtype:.bfloat16),
            fullKeys:MLXArray.full([1,2,frontier,512],values:MLXArray(2),dtype:.bfloat16),
            fullValues:MLXArray.full([1,2,frontier,512],values:MLXArray(3),dtype:.bfloat16),
            slidingKeys:MLXArray.full([1,8,min(frontier,1024),256],values:MLXArray(4),dtype:.bfloat16),
            slidingValues:MLXArray.full([1,8,min(frontier,1024),256],values:MLXArray(5),dtype:.bfloat16))
    }
    static func requireContents(_ capture: Gemma4OwnedMTPConditioning, check: () throws -> Void) throws {
        for (array,value) in zip(capture.evaluationRoots,[1,2,3,4,5]) {
            let exact = all(array .== value)
            eval(exact); try Gemma4MTPPullNativeFence.join(check:check)
            guard exact.item(Bool.self) else { throw ProbeError("Transferred qualification snapshot differs") }
        }
    }
    static func barrier(_ name: String, input: Gemma4RemoteMTPInput, group: Collective,
                        check: () throws -> Void) throws {
        func bytes(_ role: String) throws -> Data {
            try PaddedControlFrame.encode(JSONSerialization.data(withJSONObject:[
                "schema":"gemma4_mtp_pull_qualification_barrier_v1","scopeSHA256":input.scopeSHA256,
                "case":name,"role":role],options:[.sortedKeys]))
        }
        let peer = 1-group.rank, own = try bytes(input.job.role)
        let expected = try bytes(group.rank == 1 ? "assistant" : "target")
        let received: Data
        if group.rank == 1 {
            try group.sendControlCompleted(own,to:peer,maximumBytes:PaddedControlFrame.byteCount,check:check)
            received = try group.receiveControlCompleted(byteCount:PaddedControlFrame.byteCount,from:peer,maximumBytes:PaddedControlFrame.byteCount,check:check)
        } else {
            received = try group.receiveControlCompleted(byteCount:PaddedControlFrame.byteCount,from:peer,maximumBytes:PaddedControlFrame.byteCount,check:check)
            guard received == expected else { throw ProbeError("Qualifier barrier identity differs") }
            try group.sendControlCompleted(own,to:peer,maximumBytes:PaddedControlFrame.byteCount,check:check)
        }
        guard received == expected else { throw ProbeError("Qualifier barrier identity differs") }
    }
}
