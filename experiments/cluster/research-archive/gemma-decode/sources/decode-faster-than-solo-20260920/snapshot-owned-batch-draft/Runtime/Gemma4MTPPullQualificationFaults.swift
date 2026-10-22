import Foundation
import MLX

enum Gemma4MTPPullQualificationFaults {
    typealias Record = Gemma4MTPPullRecord
    private enum Injected: Error { case afterReceive }
    static func receiveRetention(input: Gemma4RemoteMTPInput, group: Collective,
                                 roots: Gemma4MTPPullQualificationRoots, check: () throws -> Void) throws {
        let hiddenDType = input.snapshotPolicy == .ownedBatch ? 3 : 1
        let plan = try Gemma4MTPPullTransferPlan(frontier:3,hiddenDType:hiddenDType)
        let wire = sha256(Data("receive-retention\n\(input.scopeSHA256)".utf8))
        let channel = try Gemma4MTPPullChannel(collective:group,role:group.rank == 1 ? .target : .assistant,targetRank:1,scopeSHA256:wire,
            snapshotPolicy:input.snapshotPolicy)
        if group.rank == 1 {
            roots.capture = try Gemma4MTPPullQualificationSupport.capture(frontier:3,hiddenDType:hiddenDType,
                noncontiguousFull:input.snapshotPolicy == .ownedBatch,check:check)
            eval(roots.capture!.evaluationRoots); try Gemma4MTPPullNativeFence.join(check:check)
            if input.snapshotPolicy == .ownedBatch {
                roots.snapshotBatch = try Gemma4MTPPullSnapshotBatch(plan:plan,direction:.send)
            }
            try Gemma4MTPPullSnapshot.send(roots.capture!,through:channel,plan:plan,batch:roots.snapshotBatch,check:check)
        } else {
            let staging = Gemma4MTPPullReceiveStaging(); roots.staging = staging
            do {
                roots.capture = try Gemma4MTPPullSnapshot.receive(through:channel,plan:plan,staging:staging,check:{
                    try check()
                    if input.snapshotPolicy == .ownedBatch, staging.snapshotBatch?.completed == true {
                        // All seven native receives/CPU and GPU boundaries passed,
                        // but NO concatenation or capture publication occurred.
                        throw Injected.afterReceive
                    }
                })
                // A single deterministic check failure after all seven actual
                // receives. This does not inject a driver/GPU/transport failure.
                throw Injected.afterReceive
            } catch Injected.afterReceive {
                guard !staging.isEmpty else { throw ProbeError("Failure discarded receive staging") }
                if input.snapshotPolicy == .ownedBatch {
                    guard roots.capture == nil, let batch = staging.snapshotBatch, batch.completed,
                          batch.outputs.count == 7 else { throw ProbeError("Preassembly failure discarded actual receive roots") }
                    for (array,value) in zip(batch.outputs,[1,2,2,3,3,4,5]) {
                        let exact = all(array .== value)
                        eval(exact); try Gemma4MTPPullNativeFence.join(check:check)
                        guard exact.item(Bool.self) else { throw ProbeError("Retained batch root differs after injected failure") }
                    }
                } else {
                    guard let capture = roots.capture else { throw ProbeError("Failure discarded receive capture") }
                    try Gemma4MTPPullQualificationSupport.requireContents(capture,check:check)
                }
                try Gemma4MTPPullNativeFence.join(check:check)
            }
        }
        // Sender remains retained through the peer's explicit fault-observed
        // checkpoint; receiver keeps all staging roots through its actual fence.
        try Gemma4MTPPullQualificationSupport.barrier("retention-fault-observed",input:input,group:group,check:check)
        try roots.releaseCompleted(check:check)
    }
    static func frame(_ ordinal: Int, input: Gemma4RemoteMTPInput, group: Collective,
                      check: () throws -> Void) throws {
        let wire = sha256(Data("frame-fault-\(ordinal)\n\(input.scopeSHA256)".utf8))
        let scope = try input.requestScope(3)
        let branch = AsyncMTPProposalLedger.BranchID(scope:scope,ordinal:0,snapshotFrontier:3,
            initialSeedToken:7,snapshotSHA256:sha256(Data("tiny-native-fault".utf8)))
        let channel = try Gemma4MTPPullChannel(collective:group,role:group.rank == 1 ? .target : .assistant,targetRank:1,scopeSHA256:wire,
            snapshotPolicy:input.snapshotPolicy)
        if group.rank == 1 {
            let frame = Record(kind:.finish,sequence:ordinal == 0 ? 1 : 0,scopeSHA256:wire,branch:branch)
            var bytes = try frame.encode()
            if ordinal == 1 { bytes[bytes.count-1] = 1 }
            try group.sendControlCompleted(bytes,to:0,maximumBytes:Record.byteCount,check:check)
        } else {
            var refused = false
            do { _ = try channel.receiveCommand(check:check) }
            catch let error as ProbeError {
                guard ordinal == 0, error.description == "Remote MTP command is stale or foreign" else { throw error }
                refused = true
            } catch let error as Record.Failure {
                guard ordinal == 1, error.reason == "Pull frame length, magic or padding differs" else { throw error }
                refused = true
            }
            guard refused else { throw ProbeError("Malformed actual frame was accepted") }
            // Refusal poisons this channel before any second physical receive.
            do {
                _ = try channel.receiveCommand(check:check)
                throw ProbeError("Poisoned qualification channel accepted reuse")
            } catch let error as ProbeError {
                guard error.description == "Remote MTP channel failed, reentered or exhausted" else { throw error }
            }
        }
        try Gemma4MTPPullNativeFence.join(check:check)
        // Fixture-only observation checkpoint, not a production request ACK or
        // permission to reuse the poisoned channel. Each case discards it.
        try Gemma4MTPPullQualificationSupport.barrier("frame-fault-\(ordinal)-observed",input:input,group:group,check:check)
    }
}
