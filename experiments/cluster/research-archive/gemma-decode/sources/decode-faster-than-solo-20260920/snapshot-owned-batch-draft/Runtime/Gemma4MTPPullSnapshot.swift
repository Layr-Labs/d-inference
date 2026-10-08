import MLX

/// The original service retains this across failed receive/concatenation fences.
final class Gemma4MTPPullReceiveStaging {
    private var roots: [MLXArray] = []
    private(set) var snapshotBatch: Gemma4MTPPullSnapshotBatch?
    var isEmpty: Bool { roots.isEmpty && snapshotBatch == nil }
    func attach(_ batch: Gemma4MTPPullSnapshotBatch) throws {
        guard isEmpty, batch.direction == .receive else { throw ProbeError("Receive staging already owns native work") }
        snapshotBatch = batch
    }
    func retain(_ array: MLXArray) throws {
        guard roots.count + (snapshotBatch?.outputs.count ?? 0) < 9 else { throw ProbeError("Remote MTP receive staging exceeded its exact nine roots") }
        roots.append(array)
    }
    func installedAfterFence() { roots.removeAll(); snapshotBatch = nil }
}

enum Gemma4MTPPullSnapshot {
    static func requireReceiverAllowance(plan: Gemma4MTPPullTransferPlan,
                                         budget: Gemma4MTPAuxiliaryBudget) throws {
        guard budget.placement == .remoteAssistant, plan.frontier <= budget.maximumFrontier,
              plan.receiverRoots.count == 9 else { throw ProbeError("Remote MTP receive has no exact auxiliary allocation scope") }
        let actual = try QwenLongPrefillCheckedBytes.sum(plan.receiverRoots.map {
            try QwenResidentResourceEnvironment.allocationBound($0.bytes)
        })
        let reserved = try QwenLongPrefillCheckedBytes.sum(budget.liveTerms.filter {
            $0.name.hasPrefix("snapshot")
        }.map(\.allocationBound))
        guard actual <= reserved else { throw ProbeError("Remote MTP independently rounded receive/assembly roots exceed the three-set allowance") }
    }
    static func typeCode(_ dtype: DType) throws -> Int {
        switch dtype {
        case .bfloat16: return 1
        case .float16: return 2
        case .float32: return 3
        default: throw ProbeError("Remote MTP hidden dtype is unsupported")
        }
    }
    static func send(_ capture: Gemma4OwnedMTPConditioning, through channel: Gemma4MTPPullChannel,
                     plan: Gemma4MTPPullTransferPlan, batch: Gemma4MTPPullSnapshotBatch? = nil,
                     check: () throws -> Void) throws {
        try validate(capture, plan: plan)
        if channel.snapshotPolicy == .ownedBatch {
            guard let batch, batch.plan.frontier == plan.frontier, batch.plan.hiddenDType == plan.hiddenDType else {
                throw ProbeError("Owned snapshot send requires original-target staging")
            }
            try channel.collective.sendOwnedSnapshotBatch(batch,capture:capture,to:channel.peer,check:check)
            guard batch.completed else { throw ProbeError("Snapshot send batch did not complete") }
            return
        }
        guard batch == nil else { throw ProbeError("Legacy snapshot cannot borrow batch staging") }
        // The caller has already admitted plan.senderAdditional and holds the
        // original evaluated capture until the actual seeded response arrives.
        let c = channel.collective, peer = channel.peer, limit = plan.maximumSingleTransferBytes
        try check()
        _ = try c.sendCompleted(capture.hidden, to: peer, maximumBytes: limit, check: check)
        for tensor in [capture.fullKeys,capture.fullValues] {
            for head in 0..<2 {
                _ = try c.sendCompleted(tensor[0...,head..<(head+1),0...,0...], to: peer,
                    maximumBytes: limit, check: check)
            }
        }
        for tensor in [capture.slidingKeys,capture.slidingValues] {
            _ = try c.sendCompleted(tensor, to: peer, maximumBytes: limit, check: check)
        }
        try check()
    }
    static func receive(through channel: Gemma4MTPPullChannel, plan: Gemma4MTPPullTransferPlan,
                        staging: Gemma4MTPPullReceiveStaging,
                        check: () throws -> Void) throws -> Gemma4OwnedMTPConditioning {
        guard staging.isEmpty else { throw ProbeError("Remote MTP receive staging has not retired") }
        if channel.snapshotPolicy == .ownedBatch {
            return try receiveBatch(through:channel,plan:plan,staging:staging,check:check)
        }
        return try MLX.withError { native in
            func checked() throws { try native.check(); try check(); try native.check() }
            let c = channel.collective, peer = channel.peer, limit = plan.maximumSingleTransferBytes
            let dtype: DType = plan.hiddenDType == 1 ? .bfloat16 : (plan.hiddenDType == 2 ? .float16 : .float32)
            try checked()
            let hidden = try c.receiveCompleted(shape:[1,1,2816],dtype:dtype,from:peer,maximumBytes:limit,check:checked)
            try staging.retain(hidden)
            var full: [MLXArray] = []
            for _ in 0..<2 {
                var heads: [MLXArray] = []
                for _ in 0..<2 {
                    let head = try c.receiveCompleted(shape:[1,1,plan.frontier,512],dtype:.bfloat16,
                        from:peer,maximumBytes:limit,check:checked)
                    try staging.retain(head); heads.append(head)
                }
                let tensor = concatenated(heads,axis:1)
                try staging.retain(tensor)
                eval(tensor); try Gemma4MTPPullNativeFence.join(check:checked)
                full.append(tensor)
            }
            var sliding: [MLXArray] = []
            for _ in 0..<2 {
                let tensor = try c.receiveCompleted(shape:[1,8,min(plan.frontier,1024),256],dtype:.bfloat16,
                    from:peer,maximumBytes:limit,check:checked)
                try staging.retain(tensor); sliding.append(tensor)
            }
            let capture = Gemma4OwnedMTPConditioning(frontier:plan.frontier,hidden:hidden,
                fullKeys:full[0],fullValues:full[1],slidingKeys:sliding[0],slidingValues:sliding[1])
            eval(capture.evaluationRoots); try Gemma4MTPPullNativeFence.join(check:checked)
            try validate(capture,plan:plan); return capture
        }
    }
    private static func receiveBatch(through channel: Gemma4MTPPullChannel, plan: Gemma4MTPPullTransferPlan,
                                     staging: Gemma4MTPPullReceiveStaging,
                                     check: () throws -> Void) throws -> Gemma4OwnedMTPConditioning {
        let batch = try Gemma4MTPPullSnapshotBatch(plan:plan,direction:.receive)
        try staging.attach(batch) // Before the first C graph or evaluation.
        return try MLX.withError { native in
            func checked() throws { try native.check(); try check(); try native.check() }
            try channel.collective.receiveOwnedSnapshotBatch(batch,from:channel.peer,check:checked)
            guard batch.completed, batch.outputs.count == 7 else { throw ProbeError("Snapshot receive batch did not complete") }
            try checked()
            // All seven receives were individually validated as owned, compact,
            // zero-offset arrays BEFORE these two aliases/assemblies exist.
            var full: [MLXArray] = []
            for start in [1,3] {
                let tensor = concatenated([batch.outputs[start],batch.outputs[start+1]],axis:1)
                try staging.retain(tensor)
                eval(tensor); try Gemma4MTPPullNativeFence.join(check:checked)
                full.append(tensor)
            }
            let capture = Gemma4OwnedMTPConditioning(frontier:plan.frontier,hidden:batch.outputs[0],
                fullKeys:full[0],fullValues:full[1],slidingKeys:batch.outputs[5],slidingValues:batch.outputs[6])
            eval(capture.evaluationRoots); try Gemma4MTPPullNativeFence.join(check:checked)
            try validate(capture,plan:plan); return capture
        }
    }
    private static func validate(_ capture: Gemma4OwnedMTPConditioning, plan: Gemma4MTPPullTransferPlan) throws {
        guard capture.frontier == plan.frontier, try typeCode(capture.hidden.dtype) == plan.hiddenDType,
              capture.hidden.shape == [1,1,2816],
              capture.fullKeys.shape == [1,2,plan.frontier,512], capture.fullValues.shape == capture.fullKeys.shape,
              capture.slidingKeys.shape == [1,8,min(plan.frontier,1024),256], capture.slidingValues.shape == capture.slidingKeys.shape,
              [capture.fullKeys,capture.fullValues,capture.slidingKeys,capture.slidingValues].allSatisfy({ $0.dtype == .bfloat16 }) else {
            throw ProbeError("Remote MTP capture differs from its admitted real target geometry")
        }
    }
}
