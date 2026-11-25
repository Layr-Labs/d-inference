import Cmlx
import Foundation
import MLX

enum Gemma4MTPPullQualificationPipeline {
    typealias Record = Gemma4MTPPullRecord
    static func run(_ ordinal: Int, input: Gemma4RemoteMTPInput, group: Collective,
                    roots: Gemma4MTPPullQualificationRoots, check: () throws -> Void) throws {
        let frontier = ordinal == 0 ? 3 : 1031, maximum = frontier+8
        let hiddenDType = input.snapshotPolicy == .ownedBatch ? ordinal+1 : 1
        let scope = try input.requestScope(ordinal)
        let requestSHA = sha256(Data("tiny-pull-fixture-\(ordinal)\n\(input.scopeSHA256)".utf8))
        let wire = Record.scopeFingerprint(scope,requestSHA256:requestSHA,initialFrontier:frontier,maximumInputFrontier:maximum)
        let snapshot = Record.captureFingerprint(scope:wire,ordinal:0,frontier:frontier,seed:7,hiddenDType:hiddenDType)
        let plan = try Gemma4MTPPullTransferPlan(frontier:frontier,hiddenDType:hiddenDType)
        let channel = try Gemma4MTPPullChannel(collective:group,role:group.rank == 1 ? .target : .assistant,targetRank:1,scopeSHA256:wire,
            snapshotPolicy:input.snapshotPolicy)
        if group.rank == 1 {
            var ledger = try AsyncMTPProposalLedger(scope:scope,inputFrontier:frontier,seedToken:7,
                maximumDraftTokens:2,maximumInputFrontier:maximum,vocabularySize:262_144)
            let branch = try ledger.startBranch(snapshotFrontier:frontier,snapshotSHA256:snapshot)
            func command(_ kind: Record.Kind) -> Record { .init(kind:kind,sequence:channel.sequence,scopeSHA256:wire,branch:branch) }
            roots.capture = try Gemma4MTPPullQualificationSupport.capture(frontier:frontier,hiddenDType:hiddenDType,
                noncontiguousFull:input.snapshotPolicy == .ownedBatch,check:check)
            eval(roots.capture!.evaluationRoots); try Gemma4MTPPullNativeFence.join(check:check)
            if input.snapshotPolicy == .ownedBatch {
                roots.snapshotBatch = try Gemma4MTPPullSnapshotBatch(plan:plan,direction:.send)
            }
            var seed = command(.seed); seed.frontier = frontier; seed.seed = 7; seed.hiddenDType = hiddenDType
            let seeded = try channel.exchange(seed,expecting:.seeded,transfer:{
                try Gemma4MTPPullSnapshot.send(roots.capture!,through:channel,plan:plan,batch:roots.snapshotBatch,check:check)
            },check:check)
            guard seeded == seed.changingKind(.seeded) else { throw ProbeError("Qualifier seed response differs") }
            // Retain actual sender roots through the exact seeded response.
            roots.snapshotBatch = nil; roots.capture = nil
            let grant = try ledger.grant(2)
            var credit = command(.credit); credit.frontier = frontier; credit.seed = 7
            credit.firstPosition = grant.firstPosition; credit.count = grant.count
            let queued = try channel.exchange(credit,expecting:.queued,check:check)
            guard queued == credit.changingKind(.queued), queued.tokens.isEmpty else { throw ProbeError("Queued fixture ACK published proposals") }
            if ordinal == 0 {
                var pull = command(.pull); pull.firstPosition = grant.firstPosition; pull.count = grant.count
                let response = try channel.exchange(pull,expecting:.proposals,check:check)
                var expected = pull.changingKind(.proposals); expected.tokens = [41,42]
                guard response == expected else { throw ProbeError("Actual fenced fixture proposals differ") }
                try ledger.receive(grant,tokens:response.tokens); try ledger.finishRequest()
            } else { ledger.cancelRequest() }
            let stop = command(ordinal == 0 ? .finish : .cancel)
            let kind: Record.Kind = ordinal == 0 ? .finished : .cancelled
            let stopped = try channel.exchange(stop,expecting:kind,check:check)
            guard stopped == stop.changingKind(kind) else { throw ProbeError("Fixture retirement response differs") }
            try ledger.branchRetired(branch,nativeWorkCompleted:true,payloadLeasesReleased:true)
            guard ledger.controlStateRetired else { throw ProbeError("Qualifier target scalar ledger remains live") }
        } else {
            let mirror = try Gemma4MTPPullMirror(scope:scope,requestSHA256:requestSHA,inputFrontier:frontier,seed:7,maximumInputFrontier:maximum)
            let seed = try channel.receiveCommand(check:check)
            guard case .install = try mirror.accept(seed) else { throw ProbeError("Qualifier expected snapshot install") }
            let staging = Gemma4MTPPullReceiveStaging(); roots.staging = staging
            roots.capture = try Gemma4MTPPullSnapshot.receive(through:channel,plan:plan,staging:staging,check:check)
            try Gemma4MTPPullQualificationSupport.requireContents(roots.capture!,check:check)
            try Gemma4MTPPullNativeFence.join(check:check); staging.installedAfterFence(); roots.staging = nil
            try channel.reply(mirror.response(.seeded),check:check); try mirror.responseSent()
            let credit = try channel.receiveCommand(check:check)
            guard case .generate(let grant) = try mirror.accept(credit) else { throw ProbeError("Qualifier expected one native credit") }
            roots.batch = (MLXArray([Int32(1),Int32(2)]) + Int32(40)).reshaped([1,2])
            try channel.reply(mirror.response(.queued),check:check); try mirror.responseSent()
            // Same production ordering: lazy roots precede ACK, then one actual
            // asynchronous submission, both C fences, then readback/later P2P.
            let tokens = try executeBatch(roots:roots,check:check)
            try mirror.generationCompleted(grant,tokens:tokens)
            if ordinal == 0 {
                let pull = try channel.receiveCommand(check:check)
                guard case .deliver = try mirror.accept(pull) else { throw ProbeError("Qualifier expected completed pull") }
                try channel.reply(mirror.response(.proposals),check:check); try mirror.responseSent()
                roots.batch = nil
            }
            let stop = try channel.receiveCommand(check:check)
            let action = try mirror.accept(stop)
            switch (ordinal,action) {
            case (0,.finish), (1,.cancel): break
            default: throw ProbeError("Qualifier stop action differs")
            }
            try roots.releaseCompleted(check:check)
            try channel.reply(mirror.response(ordinal == 0 ? .finished : .cancelled),check:check)
            try mirror.responseSent()
            guard mirror.ledger.controlStateRetired else { throw ProbeError("Qualifier assistant ledger remains live") }
        }
        try roots.releaseCompleted(check:check)
    }
    private static func executeBatch(roots: Gemma4MTPPullQualificationRoots,
                                     check: () throws -> Void) throws -> [Int] {
        guard let batch = roots.batch else { throw ProbeError("Qualifier batch disappeared before submit") }
        let vector = [batch.ctx].withUnsafeBufferPointer { mlx_vector_array_new_data($0.baseAddress,$0.count) }
        defer { mlx_vector_array_free(vector) }
        let status = mlx_async_eval(vector)
        try Gemma4MTPPullNativeFence.join(check:check)
        guard status == 0 else { throw ProbeError("Qualifier native submission failed") }
        let tokens = batch.asArray(Int32.self).map(Int.init)
        guard tokens == [41,42] else { throw ProbeError("Qualifier GPU result differs") }
        return tokens
    }

}
