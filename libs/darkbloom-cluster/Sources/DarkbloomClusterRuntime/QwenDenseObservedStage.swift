import Foundation

/// Validates the existing compact inventory records, not another receipt format.
/// These are pre-load scalar checks, not proof of resident values, array ownership
/// or a resource admission. No existing materializer calls this registered API.
enum QwenDenseObservedStageValidation {
    static func validateRegistered(source: QwenDenseSourceReadPlan,
        profile: QwenRegisteredDenseModelProfile, requirement: QwenDenseStorageRequirement,
        plan: QwenLayerStagePlan, stageIndex: Int, active: [QwenStageActiveTensor],
        inert: [QwenStageInertModule], summary: QwenStageStorageSummary
    ) throws {
        let rebuilt = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: requirement.role)
        guard [0, 1].contains(stageIndex), rebuilt.fingerprint == requirement.fingerprint,
              source.registeredProfileFingerprint == profile.fingerprint,
              source.registeredRequirementFingerprint == requirement.fingerprint,
              requirement.role == .sequentialPair || requirement.role.stageIndex == stageIndex else {
            throw ProbeError("Registered compact inventory uses a different source, Plan, role or stage")
        }
        let stage = plan.stages[stageIndex], expected = requirement.stages[stageIndex]
        let sourceTensors = Dictionary(uniqueKeysWithValues: source.tensors.map { ($0.canonical.name, $0) })
        let mappings = try plan.parameters(canonicalSourceNames: source.tensors.map { $0.canonical.name })
            .filter { $0.stage == stageIndex }.sorted { $0.localName < $1.localName }
        guard active.count == mappings.count, active.map(\.localName) == mappings.map(\.localName),
              Set(active.map(\.sourceName)).count == active.count else {
            throw ProbeError("Registered active inventory has missing, duplicate, unordered or unowned names")
        }
        for (actual, mapping) in zip(active, mappings) {
            guard let tensor = sourceTensors[mapping.sourceName], actual.sourceName == mapping.sourceName,
                  actual.shape == tensor.canonical.shape,
                  actual.sourceDType == sourceDTypeName(tensor.canonical.sourceDType),
                  actual.loadedDType == tensor.loadedDType, actual.byteCount == tensor.canonical.byteCount,
                  stage.activeModuleRoots.contains(where: { actual.localName.hasPrefix($0 + ".") }) else {
                throw ProbeError("Registered compact source/local descriptor differs: \(actual.localName)")
            }
        }
        let expectedInert = stage.inertModules.sorted { $0.path < $1.path }
        guard inert.count == expectedInert.count, inert.map(\.path) == expectedInert.map(\.path) else {
            throw ProbeError("Registered compact inactive module inventory differs")
        }
        for (actual, expected) in zip(inert, expectedInert) {
            let norm = expected.path == "model.norm" || expected.path.hasSuffix(".model.norm")
            guard actual.responsibility == expected.responsibility,
                  actual.replacementKind == (norm ? "parameter-only-replacement" : "module-replacement"),
                  actual.parameters.count == 1 else {
                throw ProbeError("Registered compact inactive replacement contract differs")
            }
            let parameter = actual.parameters[0]
            guard parameter.localName == expected.path + ".weight",
                  parameter.shape == (norm ? [profile.geometry.hiddenSize] : [1, profile.geometry.hiddenSize]),
                  parameter.dtype == profile.requiredNativeDType,
                  parameter.byteCount == profile.geometry.hiddenSize * 2 else {
                throw ProbeError("Registered compact inactive parameter differs")
            }
        }
        let inactive = inert.flatMap(\.parameters)
        guard Set(inactive.map(\.localName)).count == inactive.count,
              Set(active.map(\.localName)).isDisjoint(with: Set(inactive.map(\.localName))) else {
            throw ProbeError("Registered compact active and inactive inventories overlap")
        }
        let activeBytes = try QwenLongPrefillCheckedBytes.sum(active.map(\.byteCount))
        let inertBytes = try QwenLongPrefillCheckedBytes.sum(inactive.map(\.byteCount))
        let activeLayout = active.map { "\($0.localName):\($0.loadedDType):\($0.shape)" }
        let inertLayout = inactive.map { "\($0.localName):\($0.dtype):\($0.shape)" }
        guard activeBytes == expected.activeBytes, inertBytes == expected.inertBytes,
              active.count == expected.canonicalCount,
              active.map(\.byteCount).max() == expected.largestHostTensorBytes,
              summary.stageIndex == stageIndex,
              summary.constructionConfigurationSHA256 == expected.constructionConfigurationSHA256,
              summary.stagePlanSHA256 == expected.stagePlanFingerprint,
              summary.activeMappingSHA256 == (try QwenDenseProfileIdentity.encodedFingerprint(active)),
              summary.activeParameterLayoutSHA256 == QwenDenseProfileIdentity.fingerprint(activeLayout.sorted()),
              summary.parameterLayoutSHA256 == QwenDenseProfileIdentity.fingerprint((activeLayout + inertLayout).sorted()),
              summary.loadedTensorBytes == activeBytes, summary.activeTensorCount == active.count,
              summary.inertTensorBytes == inertBytes, summary.inertTensorCount == inactive.count else {
            throw ProbeError("Registered compact inventory accounting or existing summary differs")
        }
    }

    private static func sourceDTypeName(_ value: String) -> String {
        switch value {
        case "U32": return "uint32"
        case "F16": return "float16"
        case "BF16": return "bfloat16"
        case "F32": return "float32"
        default: return "unsupported"
        }
    }
}
