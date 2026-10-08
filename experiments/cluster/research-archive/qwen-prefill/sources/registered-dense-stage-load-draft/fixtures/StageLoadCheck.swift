import Foundation

struct QwenDenseStageLoadCheckResult: Encodable {
    let kind = "qwen_dense_selected_stage_load_admission_check", schemaVersion = 1
    let accepted: [String], rejected: [String]
    let observationsAreSynthetic = true, allocatorBoundsAreSynthetic = true
    let modelConstructed = false, currentResourcesObserved = false, loadPermissionCreated = false
    let tensorPayloadRead = false, nativeWorkPerformed = false
}

/// Reuses the public observed-fixture builders and real registered validators.
/// Unit-sized invented pages permit exact one-byte policy-boundary assertions;
/// no fake snapshot can instantiate the private production gate.
func checkQwenDenseStageLoading(_ inputs: QwenObservedFixtureInputs) throws -> QwenDenseStageLoadCheckResult {
    var accepted: [String] = [], rejected: [String] = []
    func require(_ name: String, _ value: Bool) throws {
        guard value else { throw ProbeError("Stage load fixture failed: " + name) }
        accepted.append(name)
    }
    func reject(_ name: String, _ body: () throws -> Void) throws {
        var fakeReads = 0
        do { try body(); fakeReads += 1 } catch {
            guard fakeReads == 0 else { throw ProbeError("Stage load refusal followed a fake read") }
            rejected.append(name); return
        }
        throw ProbeError("Stage load fixture admitted: " + name)
    }
    let args = ["--mode", QwenDenseStageLoadCLI.mode, "--model-dir", "/invented-stage-model",
        "--registered-dense-profile", "registered_qwen35_9b", "--stage-index", "0", "--timeout-seconds", "120"]
    for model in QwenRegisteredDenseModel.allCases {
        for index in [0, 1] {
            var values = args; values[5] = model.rawValue; values[7] = String(index)
            let cli = try QwenDenseStageLoadCLI(arguments: values)
            try require("CLI " + model.rawValue + String(index), cli.model == model && cli.stageIndex == index)
        }
    }
    let reversed = stride(from: 8, through: 0, by: -2).flatMap { Array(args[$0...($0 + 1)]) }
    try require("CLI pair order", try QwenDenseStageLoadCLI(arguments: reversed).stageIndex == 0)
    try require("CLI does not intercept unrelated value", !QwenDenseStageLoadCLI.isRequested([
        "--mode", "qwen-layer-stage-compare", "--tokens-file", QwenDenseStageLoadCLI.mode]))
    for timeout in ["1", "300"] {
        var values = args; values[9] = timeout
        try require("CLI timeout " + timeout, try QwenDenseStageLoadCLI(arguments: values).timeoutSeconds == Int(timeout))
    }
    for offset in stride(from: 0, to: 10, by: 2) {
        var missing = args; missing.removeSubrange(offset...(offset + 1))
        try reject("CLI missing " + args[offset]) { _ = try QwenDenseStageLoadCLI(arguments: missing) }
        try reject("CLI duplicate " + args[offset]) { _ = try QwenDenseStageLoadCLI(arguments: args + Array(args[offset...(offset + 1)])) }
    }
    for (position, value) in [(1, "qwen-dense-constructor-check"), (3, "relative"), (3, "/invalid\u{0}path"),
        (5, "unknown"), (7, "-1"), (7, "2"), (7, "01"), (9, "0"), (9, "301"), (9, "+1"), (9, "01"), (9, "1.0")] {
        var changed = args; changed[position] = value
        try reject("CLI value \(position) \(value)") { _ = try QwenDenseStageLoadCLI(arguments: changed) }
    }
    for flag in ["--tokens-file", "--stage-cut", "--transport", "--prefill-phase-trace-file", "--repeats", "--resource-ceiling"] {
        try reject("CLI foreign " + flag) { _ = try QwenDenseStageLoadCLI(arguments: args + [flag, "1"]) }
    }

    let gib = QwenDenseStageLoadPolicy.gib
    func os(_ free: Int, extraInactive: Int = 0, pressure: Int = 1, swap: Int = 0,
        start: UInt64 = 10, end: UInt64 = 11, rawDelta: Int = 0, byteDelta: Int = 0,
        pageSize: Int = 1, physical: Int = 64 * 1_073_741_824
    ) -> QwenDenseStageLoadOSObservation {
        .init(startedNanoseconds: start, completedNanoseconds: end, timestampUTC: "synthetic",
            physicalMemoryBytes: physical, pageSizeBytes: pageSize, kernelFreePages: free + rawDelta,
            freePages: free, inactivePages: extraInactive, speculativePages: 0,
            actualFreeBytes: free + byteDelta, estimatedReclaimableBytes: free + extraInactive,
            pressureLevel: pressure, swapUsedBytes: swap)
    }
    func native(limit: Int = 64 * 1_073_741_824, active: Int = 0, cache: Int = 0, peak: Int = 0) -> QwenDenseStageLoadNativeObservation {
        .init(activeBytes: active, cacheBytes: cache, peakBytes: peak, allocatorLimitBytes: limit)
    }
    try QwenDenseStageLoadPolicy.requireInitial(os(6 * gib), now: 11)
    try require("exact 6GiB initial floor", true)
    try reject("one byte below initial floor despite reclaimable") {
        try QwenDenseStageLoadPolicy.requireInitial(os(6 * gib - 1, extraInactive: 16 * gib), now: 11)
    }

    for (input, large) in [(inputs.nine, false), (inputs.twentySeven, true)] {
        let profile = try fixtureProfile(input, large: large), plan = try profile.makePlanningPlan()
        let metadata = try QwenDenseConstructorAdmission.admit(model: profile.model, configuration: input.configuration,
            manifest: input.manifest, environment: QwenLongPrefillArithmeticEnvironment.requiredValues)
        let pair = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: .sequentialPair)
        let source = try QwenDenseObservedSourceValidation.validateRegistered(profile.canonicalTensors.map { fixtureObserved($0) },
            identity: fixtureIdentity(profile), profile: profile, requirement: pair, plan: plan)
        for index in [-1, 2] {
            try reject(profile.model.rawValue + " selection " + String(index)) { _ = try QwenDenseStageLoadSelection(metadata: metadata, stageIndex: index) }
        }
        try reject(profile.model.rawValue + " changed raw configuration") {
            _ = try QwenDenseConstructorAdmission.admit(model: profile.model, configuration: input.configuration + Data([32]),
                manifest: input.manifest, environment: QwenLongPrefillArithmeticEnvironment.requiredValues)
        }
        try reject(profile.model.rawValue + " wrong selected profile") {
            _ = try QwenDenseConstructorAdmission.admit(model: large ? .qwen35NineB : .qwen38TwentySevenB,
                configuration: input.configuration, manifest: input.manifest,
                environment: QwenLongPrefillArithmeticEnvironment.requiredValues)
        }
        if !large {
            let unequalPlan = try profile.makePlanningPlan(stageCut: 12)
            let unequalPair = try QwenDenseStorageRequirement.derive(profile: profile, plan: unequalPlan, role: .sequentialPair)
            let unequalRole = try QwenDenseStorageRequirement.derive(profile: profile, plan: unequalPlan, role: .stage0)
            let unequalSource = try QwenDenseObservedSourceValidation.validateRegistered(profile.canonicalTensors.map { fixtureObserved($0) },
                identity: fixtureIdentity(profile), profile: profile, requirement: unequalPair, plan: unequalPlan)
            let unequal = try fixtureStage(profile, plan: unequalPlan, stageIndex: 0)
            try reject("otherwise valid cut12 is outside default-half load scope") {
                _ = try QwenDenseStageLoadBudget.derive(profile: profile, plan: unequalPlan, pair: unequalPair,
                    selected: unequalRole, source: unequalSource, stageIndex: 0, active: unequal.active, inert: unequal.inert,
                    summary: unequal.summary, allocationBounds: unequal.active.map(\.byteCount),
                    inertAllocationBounds: unequal.inert.flatMap(\.parameters).map(\.byteCount))
            }
        }
        for index in [0, 1] {
            let label = profile.model.rawValue + " stage" + String(index)
            let selected = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: index == 0 ? .stage0 : .stage1)
            let other = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: index == 0 ? .stage1 : .stage0)
            let fixture = try fixtureStage(profile, plan: plan, stageIndex: index)
            func budget(_ value: QwenObservedStageFixture? = nil, role: QwenDenseStorageRequirement? = nil,
                bounds: [Int]? = nil, pairValue: QwenDenseStorageRequirement? = nil
            ) throws -> QwenDenseStageLoadBudget {
                let v = value ?? fixture
                return try .derive(profile: profile, plan: plan, pair: pairValue ?? pair, selected: role ?? selected,
                    source: source, stageIndex: index, active: v.active, inert: v.inert, summary: v.summary,
                    allocationBounds: bounds ?? v.active.map(\.byteCount), inertAllocationBounds: v.inert.flatMap(\.parameters).map(\.byteCount))
            }
            let value = try budget(), selection = try QwenDenseStageLoadSelection(metadata: metadata, stageIndex: index)
            try require(label + " exact role and unpermitted metadata", selection.stageIndex == index && !value.resourceAdmissionPerformed &&
                value.roundedResidentBytes == selected.selectedActiveBytes + selected.selectedInertBytes)
            try reject(label + " other role") { _ = try budget(role: other) }
            try reject(label + " stage requirement cannot replace pair metadata") { _ = try budget(pairValue: selected) }
            try reject(label + " missing coherently rehashed inventory") {
                var changed = fixture; changed.active.removeLast()
                changed.summary = try fixtureStageSummary(active: changed.active, inert: changed.inert, stage: plan.stages[index])
                _ = try budget(changed)
            }
            try reject(label + " wrong loaded dtype") {
                var changed = fixture
                changed.active[0] = try fixtureChanging(changed.active[0]) { $0["loadedDType"] = "float16" }
                changed.summary = try fixtureStageSummary(active: changed.active, inert: changed.inert, stage: plan.stages[index])
                _ = try budget(changed)
            }
            try reject(label + " too-small allocator bound") {
                var bounds = fixture.active.map(\.byteCount); bounds[0] -= 1; _ = try budget(bounds: bounds)
            }
            try reject(label + " allocator sum overflow") {
                var bounds = fixture.active.map(\.byteCount); bounds[0] = Int.max; _ = try budget(bounds: bounds)
            }
            try reject(label + " out-of-order tensor") { try value.requireEntry(value.active[1], ordinal: 0) }
            try reject(label + " exhausted permission ordinal") { try value.requireEntry(value.active[0], ordinal: value.active.count) }
            let required = max(6 * gib, value.roundedResidentBytes + 2 * value.largestHostTensorBytes + 4 * gib)
            let allocator = value.roundedResidentBytes + value.largestHostTensorBytes + 2 * gib
            let decision = try QwenDenseStageLoadPolicy.evaluate(budget: value, ordinal: 0, os: os(required), native: native(limit: allocator), now: 11)
            try require(label + " exact actual-free and allocator boundary", decision.requiredActualFreeBytes == required &&
                decision.requiredAllocatorBytes == allocator && !decision.reclaimableUsedForAdmission)
            try reject(label + " actual-free one byte low") {
                _ = try QwenDenseStageLoadPolicy.evaluate(budget: value, ordinal: 0, os: os(required - 1, extraInactive: 16 * gib), native: native(), now: 11)
            }
            try reject(label + " allocator one byte low") {
                _ = try QwenDenseStageLoadPolicy.evaluate(budget: value, ordinal: 0, os: os(required), native: native(limit: allocator - 1), now: 11)
            }
            let last = try QwenDenseStageLoadPolicy.evaluate(budget: value, ordinal: value.active.count,
                os: os(6 * gib), native: native(active: selected.selectedActiveBytes, peak: selected.selectedActiveBytes), now: 11)
            try require(label + " completed buffers not double-budgeted", last.requiredActualFreeBytes == 6 * gib &&
                last.remainingAllocationBytes == value.inertAllocationBound)
            for (name, observation, clock) in [
                ("pressure", os(required, pressure: 3), UInt64(11)), ("swap", os(required, swap: 1), 11),
                ("backward capture", os(required, start: 12), 12), ("future sample", os(required), 10),
                ("stale sample", os(required), 1_000_000_012), ("raw free accounting", os(required, rawDelta: 1), 11),
                ("free byte accounting", os(required, byteDelta: 1), 11), ("zero page size", os(required, pageSize: 0), 11),
                ("page product overflow", os(required, pageSize: Int.max), 11), ("physical memory", os(required, physical: required - 1), 11)] {
                try reject(label + " " + name) { _ = try QwenDenseStageLoadPolicy.evaluate(budget: value, ordinal: 0, os: observation, native: native(), now: clock) }
            }
            try reject(label + " invalid native peak") {
                _ = try QwenDenseStageLoadPolicy.evaluate(budget: value, ordinal: 0, os: os(required), native: native(active: 1), now: 11)
            }
        }
    }
    guard accepted.count == 21, rejected.count == 122 else {
        throw ProbeError("Stage load fixture counts changed: \(accepted.count)/\(rejected.count)")
    }
    return .init(accepted: accepted, rejected: rejected)
}
