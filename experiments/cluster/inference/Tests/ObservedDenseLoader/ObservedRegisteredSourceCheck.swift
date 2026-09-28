import Foundation

func checkObservedRegisteredSources(_ inputs: QwenObservedFixtureInputs,
    _ checks: inout QwenObservedFixtureChecks) throws {
    let nine = try fixtureProfile(inputs.nine, large: false)
    let large = try fixtureProfile(inputs.twentySeven, large: true)
    for profile in [nine, large] {
        let label = profile.model.rawValue
        let plan = try profile.makePlanningPlan()
        let requirement = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: .fullReference)
        let identity = fixtureIdentity(profile)
        let values = profile.canonicalTensors.map { fixtureObserved($0) }
        func validate(_ observed: [QwenDenseObservedSourceTensor], identity: QwenDenseObservedSourceIdentity? = nil,
            requirement otherRequirement: QwenDenseStorageRequirement? = nil,
            plan otherPlan: QwenLayerStagePlan? = nil) throws -> QwenDenseSourceReadPlan {
            try QwenDenseObservedSourceValidation.validateRegistered(observed, identity: identity ?? fixtureIdentity(profile),
                profile: profile, requirement: otherRequirement ?? requirement, plan: otherPlan ?? plan)
        }
        let actual = try validate(Array(values.reversed()))
        try checks.require(label + " complete observed synthetic source", actual.tensors.map(\.canonical) == profile.canonicalTensors &&
            actual.sourceBytes == profile.sourceTensorBytes && actual.largestSourceBytes == profile.largestSourceTensorBytes &&
            actual.registeredRequirementFingerprint == requirement.fingerprint && !actual.runtimeExecutionAuthorized)
        if profile.model == .qwen35NineB {
            let old = try QwenDenseObservedSourceValidation.validateLegacy(values, convertBF16: true, purpose: .diagnostic)
            try checks.require("registered9B legacy descriptor equality", actual.sourceBytes == old.sourceBytes && actual.expectedLayoutSHA256 == old.expectedLayoutSHA256)
            let logs = actual.tensors.filter { $0.canonical.name.hasSuffix(".A_log") }
            try checks.require("registered9B real A_log remains float32", logs.count == 24 && logs.allSatisfy { $0.loadedDType == "float32" })
        } else {
            try checks.reject("registered27B still refused by legacy source limits") {
                _ = try QwenDenseObservedSourceValidation.validateLegacy(values, convertBF16: true, purpose: .diagnostic)
            }
        }
        let wrong = String(repeating: "0", count: 64)
        let identities: [(String, QwenDenseObservedSourceIdentity)] = [
            ("artifact", .init(aggregateSHA256: wrong, configurationSHA256: identity.configurationSHA256, verifiedManifestSHA256: identity.verifiedManifestSHA256, retainedSourceCount: identity.retainedSourceCount, bf16ConversionEnabled: true)),
            ("configuration", .init(aggregateSHA256: identity.aggregateSHA256, configurationSHA256: wrong, verifiedManifestSHA256: identity.verifiedManifestSHA256, retainedSourceCount: identity.retainedSourceCount, bf16ConversionEnabled: true)),
            ("missing raw manifest", .init(aggregateSHA256: identity.aggregateSHA256, configurationSHA256: identity.configurationSHA256, verifiedManifestSHA256: nil, retainedSourceCount: identity.retainedSourceCount, bf16ConversionEnabled: true)),
            ("wrong raw manifest", .init(aggregateSHA256: identity.aggregateSHA256, configurationSHA256: identity.configurationSHA256, verifiedManifestSHA256: wrong, retainedSourceCount: identity.retainedSourceCount, bf16ConversionEnabled: true)),
            ("raw rather than retained count", .init(aggregateSHA256: identity.aggregateSHA256, configurationSHA256: identity.configurationSHA256, verifiedManifestSHA256: identity.verifiedManifestSHA256, retainedSourceCount: profile.model == .qwen35NineB ? 1291 : 2211, bf16ConversionEnabled: true)),
            ("conversion policy", .init(aggregateSHA256: identity.aggregateSHA256, configurationSHA256: identity.configurationSHA256, verifiedManifestSHA256: identity.verifiedManifestSHA256, retainedSourceCount: identity.retainedSourceCount, bf16ConversionEnabled: false)),
        ]
        for (reason, identity) in identities {
            try checks.reject(label + " identity " + reason) { _ = try validate(values, identity: identity) }
        }
        let other = profile.model == .qwen35NineB ? large : nine
        let otherPlan = try other.makePlanningPlan()
        let otherRequirement = try QwenDenseStorageRequirement.derive(profile: other, plan: otherPlan, role: .fullReference)
        try checks.reject(label + " foreign requirement") { _ = try validate(values, requirement: otherRequirement) }
        try checks.reject(label + " foreign Plan") { _ = try validate(values, plan: otherPlan) }
        try checks.reject(label + " missing canonical") { _ = try validate(Array(values.dropLast())) }
        try checks.reject(label + " duplicate canonical") { _ = try validate(values + [values[0]]) }
        var changed = values
        let first = changed[0].canonical
        changed[0] = fixtureObserved(.init(name: first.name + "_extra", shape: first.shape, sourceDType: first.sourceDType, byteCount: first.byteCount))
        try checks.reject(label + " extra canonical") { _ = try validate(changed) }
        let i = values.firstIndex { $0.canonical.shape.count == 2 && $0.canonical.shape[0] != $0.canonical.shape[1] }!
        let old = values[i].canonical
        changed = values
        changed[i] = fixtureObserved(.init(name: old.name, shape: Array(old.shape.reversed()), sourceDType: old.sourceDType, byteCount: old.byteCount))
        try checks.reject(label + " coherent same-byte wrong shape") { _ = try validate(changed) }
        let j = values.firstIndex { $0.canonical.sourceDType == "BF16" }!
        let bf16 = values[j].canonical
        changed = values
        changed[j] = fixtureObserved(.init(name: bf16.name, shape: bf16.shape, sourceDType: "F16", byteCount: bf16.byteCount))
        try checks.reject(label + " coherent same-byte wrong stored dtype") { _ = try validate(changed) }
        changed = values; changed[0] = fixtureObserved(first, parts: 2)
        try checks.reject(label + " composed source") { _ = try validate(changed) }
        changed = values; changed[0] = fixtureObserved(first, packed: first.sourceDType != "U32")
        try checks.reject(label + " actual constructor class") { _ = try validate(changed) }
    }
}
