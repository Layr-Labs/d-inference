import Foundation

struct QwenDenseShortPairLoadCheckResult: Encodable {
    let kind = "qwen_dense_short_pair_load_admission_check", schemaVersion = 1
    let accepted: [String], rejected: [String]
    let resourceObservationsAreSynthetic = true, allocationBoundsAreSynthetic = true
    let currentResourcesObserved = false, privateGateExecuted = false
    let modelConstructed = false, tensorPayloadRead = false, forwardExecuted = false
}

func checkQwenDenseShortPairLoading(_ inputs: QwenObservedFixtureInputs) throws -> QwenDenseShortPairLoadCheckResult {
    var accepted: [String] = [], rejected: [String] = []
    func require(_ name: String, _ value: Bool) throws {
        guard value else { throw ProbeError("Short pair fixture failed: " + name) }
        accepted.append(name)
    }
    func reject(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(name); return }
        throw ProbeError("Short pair fixture admitted: " + name)
    }
    let gib = QwenDenseStageLoadPolicy.gib
    let prompt = Data("[1,2,3]".utf8), teacher = Data("[4]".utf8)
    func progress(_ stage: Int, _ ordinal: Int) -> QwenDenseShortPairLoadProgress {
        .init(completedStages: stage, tensorOrdinal: ordinal)
    }
    func os(_ free: Int, inactive: Int = 0, pressure: Int = 1, swap: Int = 0,
        start: UInt64 = 10, end: UInt64 = 11, rawDelta: Int = 0, byteDelta: Int = 0,
        physical: Int = 64 * 1_073_741_824
    ) -> QwenDenseStageLoadOSObservation {
        .init(startedNanoseconds: start, completedNanoseconds: end, timestampUTC: "synthetic",
            physicalMemoryBytes: physical, pageSizeBytes: 1, kernelFreePages: free + rawDelta,
            freePages: free, inactivePages: inactive, speculativePages: 0,
            actualFreeBytes: free + byteDelta, estimatedReclaimableBytes: free + inactive,
            pressureLevel: pressure, swapUsedBytes: swap)
    }
    func native(limit: Int = 64 * 1_073_741_824, active: Int = 0, cache: Int = 0, peak: Int = 0) -> QwenDenseStageLoadNativeObservation {
        .init(activeBytes: active, cacheBytes: cache, peakBytes: peak, allocatorLimitBytes: limit)
    }
    for (input, large) in [(inputs.nine, false), (inputs.twentySeven, true)] {
        let profile = try fixtureProfile(input, large: large), plan = try profile.makePlanningPlan()
        let label = profile.model.rawValue
        let metadata = try QwenDenseConstructorAdmission.admit(model: profile.model, configuration: input.configuration,
            manifest: input.manifest, environment: QwenLongPrefillArithmeticEnvironment.requiredValues)
        func admit(_ id: String) throws -> QwenDenseShortReferenceAdmission {
            try .admit(metadata: metadata, requestID: UUID(uuidString: id)!, promptData: prompt, promptSHA256: sha256(prompt),
                teacherData: teacher, teacherSHA256: sha256(teacher))
        }
        let admission = try admit("20000000-0000-0000-0000-000000000001")
        let other = try admit("20000000-0000-0000-0000-000000000002")
        let pair = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: .sequentialPair)
        let full = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: .fullReference)
        func source(_ role: QwenDenseStorageRequirement) throws -> QwenDenseSourceReadPlan {
            try QwenDenseObservedSourceValidation.validateRegistered(profile.canonicalTensors.map { fixtureObserved($0) },
                identity: fixtureIdentity(profile), profile: profile, requirement: role, plan: plan)
        }
        let observed = try source(pair)
        let stages = try [0, 1].map { index in
            let inventory = try fixtureStage(profile, plan: plan, stageIndex: index)
            let selected = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan,
                role: index == 0 ? .stage0 : .stage1)
            return try QwenDenseStageLoadBudget.derive(profile: profile, plan: plan, pair: pair, selected: selected,
                source: observed, stageIndex: index, active: inventory.active, inert: inventory.inert, summary: inventory.summary,
                allocationBounds: inventory.active.map(\.byteCount), inertAllocationBounds: inventory.inert.flatMap(\.parameters).map(\.byteCount))
        }
        let ledger = try QwenDenseShortRequestLedger.derive(profile: profile, plan: plan, request: admission.request,
            scope: .sequentialStagePair, allocationFootprintUpperBound: { $0 })
        let fullLedger = try QwenDenseShortRequestLedger.derive(profile: profile, plan: plan, request: admission.request,
            scope: .fullReference, allocationFootprintUpperBound: { $0 })
        let otherLedger = try QwenDenseShortRequestLedger.derive(profile: profile, plan: plan, request: other.request,
            scope: .sequentialStagePair, allocationFootprintUpperBound: { $0 })
        func budget(role: QwenDenseStorageRequirement? = nil, readPlan: QwenDenseSourceReadPlan? = nil,
            requestLedger: QwenDenseShortRequestLedger? = nil, stageBudgets: [QwenDenseStageLoadBudget]? = nil
        ) throws -> QwenDenseShortPairLoadBudget {
            try .derive(profile: profile, plan: plan, requirement: role ?? pair, source: readPlan ?? observed,
                admission: admission, ledger: requestLedger ?? ledger, stages: stageBudgets ?? stages)
        }
        let value = try budget(), s0 = stages[0], s1 = stages[1]
        let allInert = s0.inertAllocationBound + s1.inertAllocationBound
        let resident0 = s0.roundedResidentBytes - s0.inertAllocationBound
        let begin = progress(0, 0), firstSettled = progress(0, s0.active.count)
        let second = progress(1, 0), secondSettled = progress(1, s1.active.count), done = progress(2, 0)
        try require(label + " pair metadata is not a grant", value.role == "sequentialStagePair" &&
            !value.resourceAdmissionPerformed && !value.forwardExecuted && value.referenceAdmissionFingerprint == admission.fingerprint &&
            value.shortLedgerFingerprint == ledger.fingerprint && value.maximumTokens == 5)
        try require(label + " exact ordered ownership and F32 preservation", stages.map({ $0.active.count }) == (large ? [923, 924] : [463, 464]) &&
            stages.map({ $0.active.filter { $0.loadedDType == "float32" }.count }) == (large ? [0, 0] : [12, 12]) &&
            Set(stages.flatMap { $0.active.map(\.sourceName) }) == Set(profile.canonicalTensors.map(\.name)))
        try require(label + " before payload all weights and inert pending", try value.remainingAllocationBytes(begin) ==
            s0.roundedResidentBytes + s1.roundedResidentBytes && value.hostAllowanceBytes(begin) == profile.largestSourceTensorBytes)
        try require(label + " stage0 inert remains pending before completion", try value.remainingAllocationBytes(firstSettled) ==
            s0.inertAllocationBound + s1.roundedResidentBytes)
        try require(label + " stage1 retains previous lazy inert allowance", try value.remainingAllocationBytes(second) == s0.inertAllocationBound + s1.roundedResidentBytes)
        try require(label + " all inert survives final active completion", try value.remainingAllocationBytes(secondSettled) == allInert &&
            value.hostAllowanceBytes(secondSettled) == 0)
        try require(label + " completed pair still reserves inert but no host read", try value.remainingAllocationBytes(done) == allInert && value.hostAllowanceBytes(done) == 0)
        for index in [0, 1] {
            try value.requireEntry(stages[index].active[0], stageIndex: index, progress: progress(index, 0))
            try value.requireEntry(stages[index].active.last!, stageIndex: index, progress: progress(index, stages[index].active.count - 1))
        }
        try require(label + " exact first and last descriptor per stage", true)
        try value.requireCompletion(stageIndex: 0, progress: firstSettled)
        try value.requireCompletion(stageIndex: 1, progress: secondSettled)
        try require(label + " exact stage completion boundaries", true)
        for (name, action) in [
            ("full role", { _ = try budget(role: full) }), ("full source role", { _ = try budget(readPlan: source(full)) }),
            ("full request ledger", { _ = try budget(requestLedger: fullLedger) }),
            ("other history ledger", { _ = try budget(requestLedger: otherLedger) }),
            ("swapped stages", { _ = try budget(stageBudgets: [s1, s0]) }),
            ("duplicate stage", { _ = try budget(stageBudgets: [s0, s0]) }),
            ("missing stage", { _ = try budget(stageBudgets: [s0]) }),
            ("extra stage", { _ = try budget(stageBudgets: [s0, s1, s1]) })] {
            try reject(label + " " + name, action)
        }
        // Each stage budget is individually representable; only composition
        // overflows. Construct outside reject so an earlier refusal cannot hide it.
        let hugeStages = try [0, 1].map { index in
            let inventory = try fixtureStage(profile, plan: plan, stageIndex: index)
            let selected = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan,
                role: index == 0 ? .stage0 : .stage1)
            var bounds = inventory.active.map(\.byteCount); bounds[0] = Int.max / 2
            return try QwenDenseStageLoadBudget.derive(profile: profile, plan: plan, pair: pair, selected: selected,
                source: observed, stageIndex: index, active: inventory.active, inert: inventory.inert, summary: inventory.summary,
                allocationBounds: bounds, inertAllocationBounds: inventory.inert.flatMap(\.parameters).map(\.byteCount))
        }
        try reject(label + " combined individually valid stage budgets overflow") { _ = try budget(stageBudgets: hugeStages) }
        for p in [progress(-1, 0), progress(3, 0), progress(0, -1), progress(0, s0.active.count + 1),
                  progress(1, s1.active.count + 1), progress(2, 1)] {
            try reject(label + " invalid progress \(p.completedStages)/\(p.tensorOrdinal)") { _ = try value.remainingAllocationBytes(p) }
        }
        for (index, p) in [(1, begin), (0, second), (2, done)] {
            try reject(label + " out-of-order stage \(index)/\(p.completedStages)") {
                try value.requireEntry(s0.active[0], stageIndex: index, progress: p)
            }
        }
        for index in [0, 1] {
            try reject(label + " out-of-order tensor stage\(index)") {
                try value.requireEntry(stages[index].active[1], stageIndex: index, progress: progress(index, 0))
            }
        }
        try reject(label + " changed descriptor dtype") {
            let changed = try fixtureChanging(s0.active[0]) { $0["loadedDType"] = "float16" }
            try value.requireEntry(changed, stageIndex: 0, progress: begin)
        }
        for (index, p) in [(0, begin), (1, firstSettled), (0, second), (1, done)] {
            try reject(label + " invalid completion \(index)/\(p.completedStages)/\(p.tensorOrdinal)") {
                try value.requireCompletion(stageIndex: index, progress: p)
            }
        }
        let r = value.roundedResidentBytes, h = value.largestHostTensorBytes, q = value.forwardReserveBytes
        let initialFree = max(6 * gib, r + 2 * h + q + (8 * 1024 * 1024 + 16 * 1024) + 4 * gib), initialAllocator = 321 + r + h + q + 2 * gib
        let first = try QwenDenseShortPairResourcePolicy.evaluate(budget: value, progress: begin,
            os: os(initialFree), native: native(limit: initialAllocator, cache: 321), now: 11)
        try require(label + " exact whole-pair initial resource boundary", first.requiredActualFreeBytes == initialFree &&
            first.requiredAllocatorBytes == initialAllocator && !first.reclaimableUsedForAdmission)
        let secondPending = s0.inertAllocationBound + s1.roundedResidentBytes
        let secondFree = max(6 * gib, secondPending + 2 * h + q + (8 * 1024 * 1024 + 16 * 1024) + 4 * gib)
        let secondAllocator = resident0 + 321 + secondPending + h + q + 2 * gib
        let middle = try QwenDenseShortPairResourcePolicy.evaluate(budget: value, progress: second,
            os: os(secondFree), native: native(limit: secondAllocator, active: resident0, cache: 321, peak: resident0), now: 11)
        try require(label + " stage0 resident remains charged during stage1", middle.remainingAllocationBytes == secondPending &&
            middle.requiredAllocatorBytes == secondAllocator && middle.requiredActualFreeBytes == secondFree)
        let finalFree = max(6 * gib, allInert + q + 4 * gib)
        let last = try QwenDenseShortPairResourcePolicy.evaluate(budget: value, progress: done,
            os: os(finalFree), native: native(active: r - allInert, peak: r - allInert), now: 11)
        try require(label + " completed pair retains inert Q and resident charge", last.remainingAllocationBytes == allInert &&
            last.forwardReserveBytes == q && last.requiredActualFreeBytes == finalFree && last.requiredAllocatorBytes == r + q + 2 * gib)
        try reject(label + " actual free one byte low despite reclaimable") {
            _ = try QwenDenseShortPairResourcePolicy.evaluate(budget: value, progress: begin,
                os: os(initialFree - 1, inactive: 8 * gib), native: native(), now: 11)
        }
        try reject(label + " allocator one byte low") {
            _ = try QwenDenseShortPairResourcePolicy.evaluate(budget: value, progress: begin,
                os: os(initialFree), native: native(limit: initialAllocator - 1, cache: 321), now: 11)
        }
        try reject(label + " allocator omits short Q") {
            _ = try QwenDenseShortPairResourcePolicy.evaluate(budget: value, progress: begin,
                os: os(initialFree), native: native(limit: r + h + 2 * gib), now: 11)
        }
        try reject(label + " stage1 cannot omit stage0 resident allocation") {
            _ = try QwenDenseShortPairResourcePolicy.evaluate(budget: value, progress: second, os: os(secondFree),
                native: native(limit: secondPending + h + q + 2 * gib, active: resident0, peak: resident0), now: 11)
        }
        for (name, sample, clock) in [("swap", os(initialFree, swap: 1), UInt64(11)),
            ("pressure", os(initialFree, pressure: 3), 11), ("stale", os(initialFree), 1_000_000_012),
            ("future", os(initialFree), 10), ("backward", os(initialFree, start: 12), 12),
            ("raw counter", os(initialFree, rawDelta: 1), 11), ("byte counter", os(initialFree, byteDelta: 1), 11),
            ("physical memory", os(initialFree, physical: initialFree - 1), 11), ("6GiB floor", os(6 * gib - 1), 11)] {
            try reject(label + " " + name) {
                _ = try QwenDenseShortPairResourcePolicy.evaluate(budget: value, progress: begin, os: sample, native: native(), now: clock)
            }
        }
        for (name, sample) in [("native peak", native(active: 1)), ("negative cache", native(cache: -1)),
                               ("allocator sum overflow", native(active: Int.max, peak: Int.max))] {
            try reject(label + " " + name) {
                _ = try QwenDenseShortPairResourcePolicy.evaluate(budget: value, progress: begin, os: os(initialFree), native: sample, now: 11)
            }
        }
    }
    guard accepted.count == 24, rejected.count == 82 else {
        throw ProbeError("Short pair fixture counts changed: \(accepted.count)/\(rejected.count)")
    }
    return .init(accepted: accepted, rejected: rejected)
}
