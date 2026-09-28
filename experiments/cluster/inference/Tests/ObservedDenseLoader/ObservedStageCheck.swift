import Foundation

func checkObservedStages(_ inputs: QwenObservedFixtureInputs, _ checks: inout QwenObservedFixtureChecks) throws {
    for (input, large) in [(inputs.nine, false), (inputs.twentySeven, true)] {
        let profile = try fixtureProfile(input, large: large), plan = try profile.makePlanningPlan()
        let label = profile.model.rawValue
        let pair = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: .sequentialPair)
        let observed = profile.canonicalTensors.map { fixtureObserved($0) }
        func source(_ requirement: QwenDenseStorageRequirement) throws -> QwenDenseSourceReadPlan {
            try QwenDenseObservedSourceValidation.validateRegistered(observed, identity: fixtureIdentity(profile),
                profile: profile, requirement: requirement, plan: plan)
        }
        let pairSource = try source(pair)
        let zero = try fixtureStage(profile, plan: plan, stageIndex: 0)
        let one = try fixtureStage(profile, plan: plan, stageIndex: 1)
        func validate(_ fixture: QwenObservedStageFixture, stage: Int = 0,
            requirement: QwenDenseStorageRequirement? = nil, source: QwenDenseSourceReadPlan? = nil) throws {
            try QwenDenseObservedStageValidation.validateRegistered(source: source ?? pairSource,
                profile: profile, requirement: requirement ?? pair, plan: plan, stageIndex: stage,
                active: fixture.active, inert: fixture.inert, summary: fixture.summary)
        }
        try validate(zero); try validate(one, stage: 1)
        try checks.require(label + " ordered complete pair inventory", [zero.active.count, one.active.count] == (large ? [923, 924] : [463, 464]) &&
            [zero.summary.inertTensorBytes, one.summary.inertTensorBytes] == (large ? [20480, 10240] : [16384, 8192]) &&
            Set(zero.active.map(\.sourceName)).isDisjoint(with: Set(one.active.map(\.sourceName))) &&
            Set((zero.active + one.active).map(\.sourceName)) == Set(profile.canonicalTensors.map(\.name)))
        if large {
            try checks.require("27B exact active stage bytes", [zero.summary.loadedTensorBytes, one.summary.loadedTensorBytes] == [7_566_395_904, 7_566_406_144])
        }
        for (role, index, fixture) in [(QwenDenseStorageRole.stage0, 0, zero), (.stage1, 1, one)] {
            let requirement = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: role)
            let selected = try source(requirement)
            try validate(fixture, stage: index, requirement: requirement, source: selected)
            try checks.require(label + " selected role " + role.rawValue, !selected.runtimeExecutionAuthorized)
            try checks.reject(label + " role replay " + role.rawValue) {
                try validate(index == 0 ? one : zero, stage: 1 - index, requirement: requirement, source: selected)
            }
            try checks.reject(label + " stale source role " + role.rawValue) {
                try validate(fixture, stage: index, requirement: requirement)
            }
        }
        let full = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: .fullReference)
        let fullSource = try source(full)
        try checks.reject(label + " full source cannot become compact permission") { try validate(zero, requirement: full, source: fullSource) }
        let legacy = try? QwenDenseObservedSourceValidation.validateLegacy(observed, convertBF16: true, purpose: .layerStage)
        if let legacy {
            try checks.reject(label + " legacy metadata cannot become registered") { try validate(zero, source: legacy) }
        }
        // Recompute all summary hashes after inventory mutation: exact source
        // ownership/shape/inert checks must still reject coherent fake records.
        func corrupt(_ label: String, _ change: (inout QwenObservedStageFixture) throws -> Void) throws {
            var fake = zero; try change(&fake)
            fake.summary = try fixtureStageSummary(active: fake.active, inert: fake.inert, stage: plan.stages[0])
            try checks.reject(profile.model.rawValue + " " + label) { try validate(fake) }
        }
        try corrupt("missing active") { $0.active.removeLast() }
        try corrupt("duplicate active") { $0.active.append($0.active[0]) }
        try corrupt("wrong source owner") { $0.active[0] = try fixtureChanging($0.active[0]) { $0["sourceName"] = one.active[0].sourceName } }
        try corrupt("wrong local name") { $0.active[0] = try fixtureChanging($0.active[0]) { $0["localName"] = "language_model.model.layers.99.weight" } }
        try corrupt("wrong active shape") { $0.active[0] = try fixtureChanging($0.active[0]) { $0["shape"] = [1] } }
        try corrupt("wrong loaded dtype") { $0.active[0] = try fixtureChanging($0.active[0]) { $0["loadedDType"] = "float16" } }
        try corrupt("wrong stored dtype") { $0.active[0] = try fixtureChanging($0.active[0]) { $0["sourceDType"] = "unsupported" } }
        try corrupt("wrong active bytes") { $0.active[0] = try fixtureChanging($0.active[0]) { $0["byteCount"] = 1 } }
        try corrupt("Plan-order rather than receipt-order inert") { $0.inert.reverse() }
        try corrupt("missing inert") { $0.inert.removeLast() }
        try corrupt("wrong replacement") { $0.inert[0] = try fixtureChanging($0.inert[0]) { $0["replacementKind"] = "parameter-only-replacement" } }
        try corrupt("wrong inert parameter") {
            let module = $0.inert[0]
            let parameter = try fixtureChanging(module.parameters[0]) { $0["shape"] = [profile.geometry.hiddenSize]; $0["dtype"] = "float16" }
            $0.inert[0] = .init(path: module.path, replacementKind: module.replacementKind, responsibility: module.responsibility, parameters: [parameter])
        }
        var fake = zero
        fake.summary = try fixtureChanging(fake.summary) { $0["stagePlanSHA256"] = plan.stages[1].fingerprint }
        try checks.reject(label + " stale summary Plan") { try validate(fake) }
        try checks.reject(label + " out of bounds stage") { try validate(zero, stage: 2) }
    }
}
