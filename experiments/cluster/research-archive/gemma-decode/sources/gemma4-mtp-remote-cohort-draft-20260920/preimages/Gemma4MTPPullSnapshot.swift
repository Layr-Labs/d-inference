import MLX

/// The original service retains this across failed receive/concatenation fences.
final class Gemma4MTPPullReceiveStaging {
    private var roots: [MLXArray] = []
    var isEmpty: Bool { roots.isEmpty }
    func retain(_ array: MLXArray) throws {
        guard roots.count < 9 else { throw ProbeError("Remote MTP receive staging exceeded its exact nine roots") }
        roots.append(array)
    }
    func installedAfterFence() { roots.removeAll() }
}

enum Gemma4MTPPullSnapshot {
    static func typeCode(_ dtype: DType) throws -> Int {
        switch dtype {
        case .bfloat16: return 1
        case .float16: return 2
        case .float32: return 3
        default: throw ProbeError("Remote MTP hidden dtype is unsupported")
        }
    }
    static func send(_ capture: Gemma4OwnedMTPConditioning, through channel: Gemma4MTPPullChannel,
                     plan: Gemma4MTPPullTransferPlan, check: () throws -> Void) throws {
        try validate(capture, plan: plan)
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
