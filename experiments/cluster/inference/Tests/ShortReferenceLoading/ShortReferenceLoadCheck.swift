import Foundation

struct QwenDenseShortReferenceLoadCheckResult: Encodable {
    let kind = "qwen_dense_short_reference_load_admission_check", schemaVersion = 1
    let accepted: [String], rejected: [String]
    let observationsAreSynthetic = true, allocatorBoundsAreSynthetic = true
    let currentResourcesObserved = false, loadPermissionCreated = false
    let modelConstructed = false, tensorPayloadRead = false, forwardExecuted = false
}

/// Real metadata/request/budget predicates. No invented observation can create
/// the file-private live gate, and no payload or model is constructed here.
func checkQwenDenseShortReferenceLoading(_ inputs: QwenObservedFixtureInputs) throws -> QwenDenseShortReferenceLoadCheckResult {
    var accepted: [String] = [], rejected: [String] = []
    func require(_ name: String, _ value: Bool) throws {
        guard value else { throw ProbeError("Short reference fixture failed: " + name) }
        accepted.append(name)
    }
    func reject(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(name); return }
        throw ProbeError("Short reference fixture admitted: " + name)
    }
    let uuid = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    let fresh = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeef")!
    let prompt = Data("[1,2,3]".utf8), teacher = Data("[4]".utf8)
    let gib = QwenDenseStageLoadPolicy.gib
    func os(_ free: Int, inactive: Int = 0, pressure: Int = 1, swap: Int = 0,
        start: UInt64 = 10, end: UInt64 = 11, rawDelta: Int = 0, byteDelta: Int = 0,
        pageSize: Int = 1, physical: Int = 64 * 1_073_741_824
    ) -> QwenDenseStageLoadOSObservation {
        .init(startedNanoseconds: start, completedNanoseconds: end, timestampUTC: "synthetic",
            physicalMemoryBytes: physical, pageSizeBytes: pageSize, kernelFreePages: free + rawDelta,
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
        let metadata = try QwenDenseConstructorAdmission.admit(model: profile.model,
            configuration: input.configuration, manifest: input.manifest,
            environment: QwenLongPrefillArithmeticEnvironment.requiredValues)
        func admit(_ p: Data = prompt, _ t: Data = teacher, id: UUID = uuid,
            pHash: String? = nil, tHash: String? = nil
        ) throws -> QwenDenseShortReferenceAdmission {
            try .admit(metadata: metadata, requestID: id, promptData: p,
                promptSHA256: pHash ?? sha256(p), teacherData: t, teacherSHA256: tHash ?? sha256(t))
        }
        let admission = try admit()
        try require(label + " exact 3/2/2 schedule and capacity", admission.maximumTokens == 5 &&
            admission.request.steps.map(\.committedTokens) == [2, 3, 4] &&
            admission.request.steps.map(\.expectsLogits) == [false, true, true] &&
            admission.request.steps.map(\.tokenIDs) == [[1, 2], [3], [4]])
        try require(label + " metadata is not permission", !admission.resourceAdmissionPerformed && !admission.forwardExecutionAuthorized)
        let spaced = try admit(Data("[1, 2, 3]\n".utf8))
        try require(label + " raw bytes remain independent of logical history",
            spaced.request.fingerprint == admission.request.fingerprint && spaced.fingerprint != admission.fingerprint &&
            spaced.promptSHA256 != admission.promptSHA256)
        let other = try admit(id: fresh)
        try require(label + " fresh UUID changes request and admission",
            other.request.fingerprint != admission.request.fingerprint && other.fingerprint != admission.fingerprint)
        let changed = try admit(prompt, Data("[5]".utf8))
        try require(label + " teacher content changes full history",
            changed.request.fingerprint != admission.request.fingerprint && changed.fingerprint != admission.fingerprint)
        for raw in ["[]", "[1,2]", "[1,2,3,4]", "[1.0,2,3]", "[true,2,3]", "[1e0,2,3]", "[-1,2,3]",
                    "[262144,2,3]", "{\"a\":1}", "[1,2,3] trailing"] {
            try reject(label + " prompt " + raw) { _ = try admit(Data(raw.utf8)) }
        }
        for raw in ["[]", "[4,5]", "[4.0]", "[false]", "[-1]", "[262144]"] {
            try reject(label + " teacher " + raw) { _ = try admit(prompt, Data(raw.utf8)) }
        }
        for (name, p, t) in [("empty prompt", Data(), teacher), ("empty teacher", prompt, Data()),
            ("oversized prompt", Data(repeating: 32, count: 4097), teacher),
            ("oversized teacher", prompt, Data(repeating: 32, count: 4097))] {
            try reject(label + " " + name) { _ = try admit(p, t) }
        }
        try reject(label + " wrong prompt raw pin") { _ = try admit(pHash: String(repeating: "0", count: 64)) }
        try reject(label + " wrong teacher raw pin") { _ = try admit(tHash: String(repeating: "0", count: 64)) }
        try reject(label + " uppercase raw pin") { _ = try admit(pHash: sha256(prompt).uppercased()) }

        let full = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: .fullReference)
        let pair = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: .sequentialPair)
        let stage = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: .stage0)
        func source(_ requirement: QwenDenseStorageRequirement) throws -> QwenDenseSourceReadPlan {
            try QwenDenseObservedSourceValidation.validateRegistered(profile.canonicalTensors.map { fixtureObserved($0) },
                identity: fixtureIdentity(profile), profile: profile, requirement: requirement, plan: plan)
        }
        let observed = try source(full)
        let ledger = try QwenDenseShortRequestLedger.derive(profile: profile, plan: plan, request: admission.request,
            scope: .fullReference, allocationFootprintUpperBound: { $0 })
        let pairLedger = try QwenDenseShortRequestLedger.derive(profile: profile, plan: plan, request: admission.request,
            scope: .sequentialStagePair, allocationFootprintUpperBound: { $0 })
        let otherLedger = try QwenDenseShortRequestLedger.derive(profile: profile, plan: plan, request: other.request,
            scope: .fullReference, allocationFootprintUpperBound: { $0 })
        let bounds = observed.tensors.map { $0.canonical.byteCount }
        func budget(role: QwenDenseStorageRequirement? = nil, readPlan: QwenDenseSourceReadPlan? = nil,
            requestLedger: QwenDenseShortRequestLedger? = nil, allocations: [Int]? = nil
        ) throws -> QwenDenseShortReferenceLoadBudget {
            try .derive(profile: profile, plan: plan, requirement: role ?? full, source: readPlan ?? observed,
                admission: admission, ledger: requestLedger ?? ledger, allocationBounds: allocations ?? bounds)
        }
        let value = try budget()
        let f32 = observed.tensors.filter { $0.canonical.sourceDType == "F32" }
        try require(label + " exact retained source-to-loaded dtype preservation",
            observed.tensors.filter { $0.loadedDType == "uint32" }.count == (large ? 498 : 250) &&
            observed.tensors.filter { $0.loadedDType == "bfloat16" }.count == (large ? 1349 : 653) &&
            observed.tensors.filter { $0.loadedDType == "float32" }.count == (large ? 0 : 24) &&
            f32.count == (large ? 0 : 24) && f32.allSatisfy {
                $0.canonical.name.hasSuffix(".linear_attn.A_log") && $0.canonical.shape == [32] &&
                $0.canonical.byteCount == 128 && $0.loadedDType == "float32"
            })
        try reject(label + " cannot widen a retained BF16 tensor to F32") {
            var changed = profile.canonicalTensors
            let i = changed.firstIndex { $0.sourceDType == "BF16" }!
            let t = changed[i]
            changed[i] = .init(name: t.name, shape: t.shape, sourceDType: "F32", byteCount: t.byteCount * 2)
            _ = try QwenDenseObservedSourceValidation.validateRegistered(changed.map { fixtureObserved($0) },
                identity: fixtureIdentity(profile), profile: profile, requirement: full, plan: plan)
        }
        if !large {
            try reject(label + " cannot narrow retained F32 A_log to BF16") {
                var changed = profile.canonicalTensors
                let i = changed.firstIndex { $0.sourceDType == "F32" }!
                let t = changed[i]
                changed[i] = .init(name: t.name, shape: t.shape, sourceDType: "BF16", byteCount: t.byteCount / 2)
                _ = try QwenDenseObservedSourceValidation.validateRegistered(changed.map { fixtureObserved($0) },
                    identity: fixtureIdentity(profile), profile: profile, requirement: full, plan: plan)
            }
        }
        try require(label + " complete full ownership without inert storage", value.tensors == profile.canonicalTensors &&
            value.tensors.count == (large ? 1847 : 927) && value.roundedResidentBytes == profile.sourceTensorBytes &&
            full.selectedInertBytes == 0 && value.role == "fullReference" && !value.resourceAdmissionPerformed)
        let padded = try budget(allocations: bounds.map { $0 + 17 })
        try require(label + " every weight keeps its individual allocation bound",
            padded.roundedResidentBytes == value.roundedResidentBytes + 17 * bounds.count &&
            padded.forwardReserveBytes == ledger.forwardReserveBytes)
        try reject(label + " pair is not full permission") { _ = try budget(role: pair) }
        try reject(label + " selected stage is not full permission") { _ = try budget(role: stage) }
        try reject(label + " pair source read plan cannot replay as full") { _ = try budget(readPlan: source(pair)) }
        try reject(label + " pair request ledger cannot replay as full") { _ = try budget(requestLedger: pairLedger) }
        try reject(label + " fresh request cannot borrow previous ledger") { _ = try budget(requestLedger: otherLedger) }
        try reject(label + " missing allocator bound") { _ = try budget(allocations: Array(bounds.dropLast())) }
        try reject(label + " too-small allocator bound") {
            var changed = bounds; changed[0] -= 1; _ = try budget(allocations: changed)
        }
        try reject(label + " allocator sum overflow") {
            var changed = bounds; changed[0] = Int.max; _ = try budget(allocations: changed)
        }
        func entry(_ tensor: QwenDenseCanonicalTensor, _ ordinal: Int) throws {
            try value.requireEntry(name: tensor.name, shape: tensor.shape, sourceDType: tensor.sourceDType,
                byteCount: tensor.byteCount, ordinal: ordinal)
        }
        try entry(value.tensors[0], 0); try entry(value.tensors.last!, value.tensors.count - 1)
        try require(label + " first and final sorted descriptors admitted", true)
        try reject(label + " out-of-order descriptor") { try entry(value.tensors[1], 0) }
        try reject(label + " consumed descriptor ordinal") { try entry(value.tensors[0], value.tensors.count) }
        try reject(label + " negative progress") { _ = try value.remainingAllocationBytes(after: -1) }
        try reject(label + " excess progress") { _ = try value.remainingAllocationBytes(after: value.tensors.count + 1) }

        let r = value.roundedResidentBytes, h = value.largestHostTensorBytes, q = value.forwardReserveBytes
        let required = max(6 * gib, r + 2 * h + q + 4 * gib)
        let allocator = 123 + 456 + r + h + q + 2 * gib
        let decision = try QwenDenseShortReferenceResourcePolicy.evaluate(budget: value, ordinal: 0,
            os: os(required), native: native(limit: allocator, active: 123, cache: 456, peak: 123), now: 11)
        try require(label + " exact initial bounds include Q and observed active/cache",
            decision.requiredActualFreeBytes == required && decision.requiredAllocatorBytes == allocator &&
            decision.forwardReserveBytes == q && !decision.reclaimableUsedForAdmission)
        try reject(label + " actual free one byte low despite reclaimable") {
            _ = try QwenDenseShortReferenceResourcePolicy.evaluate(budget: value, ordinal: 0,
                os: os(required - 1, inactive: 8 * gib), native: native(), now: 11)
        }
        try reject(label + " allocator one byte low") {
            _ = try QwenDenseShortReferenceResourcePolicy.evaluate(budget: value, ordinal: 0,
                os: os(required), native: native(limit: allocator - 1, active: 123, cache: 456, peak: 123), now: 11)
        }
        let completeRequired = max(6 * gib, q + 4 * gib)
        let completed = try QwenDenseShortReferenceResourcePolicy.evaluate(budget: value, ordinal: value.tensors.count,
            os: os(completeRequired), native: native(active: r, peak: r), now: 11)
        try require(label + " loaded weights leave R while forward Q remains reserved",
            completed.remainingAllocationBytes == 0 && completed.forwardReserveBytes == q &&
            completed.requiredActualFreeBytes == completeRequired && completed.requiredAllocatorBytes == r + q + 2 * gib)
        for (name, observation, clock) in [
            ("below 6GiB floor", os(6 * gib - 1), UInt64(11)),
            ("swap", os(required, swap: 1), 11), ("pressure", os(required, pressure: 3), 11),
            ("backward capture", os(required, start: 12), 12), ("future sample", os(required), 10),
            ("stale sample", os(required), 1_000_000_012), ("raw counter mismatch", os(required, rawDelta: 1), 11),
            ("byte counter mismatch", os(required, byteDelta: 1), 11), ("zero page size", os(required, pageSize: 0), 11),
            ("page product overflow", os(required, pageSize: Int.max), 11),
            ("physical memory", os(required, physical: required - 1), 11)] {
            try reject(label + " " + name) {
                _ = try QwenDenseShortReferenceResourcePolicy.evaluate(budget: value, ordinal: 0,
                    os: observation, native: native(), now: clock)
            }
        }
        try reject(label + " invalid native peak") {
            _ = try QwenDenseShortReferenceResourcePolicy.evaluate(budget: value, ordinal: 0,
                os: os(required), native: native(active: 1), now: 11)
        }
    }
    guard accepted.count == 22, rejected.count == 101 else {
        throw ProbeError("Short reference fixture counts changed: \(accepted.count)/\(rejected.count)")
    }
    return .init(accepted: accepted, rejected: rejected)
}
