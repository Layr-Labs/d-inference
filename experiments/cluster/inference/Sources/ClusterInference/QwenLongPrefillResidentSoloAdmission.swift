import Foundation

/// Reuses the exact registered admission and one-shot Options constraints.
/// The worker owns actual process arithmetic/resources, deadline and commands.
enum QwenLongPrefillResidentSoloAdmission {
    static func validate(options: Options,
        requests: [QwenRegistered9BLongPrefillReferenceAdmission], warmupCount: Int
    ) throws -> [QwenLongPrefillResidentRequestStep] {
        _ = try QwenLongPrefillSoloCLI.referenceOptions(options)
        guard options.prefillPhaseTraceFile == nil, options.prefillOwnerTraceFile == nil,
              (1...4).contains(requests.count), (0..<requests.count).contains(warmupCount),
              let first = requests.first,
              first.resource.expectedArtifactAggregateSHA256 == options.expectedArtifactAggregateSHA256,
              first.promptFileSHA256 == options.longPromptSHA256 else {
            throw ProbeError("Resident solo requires bounded requests, a measured request and pinned initial input")
        }
        let resource = try canonicalJSONData(first.resource)
        var steps: [QwenLongPrefillResidentRequestStep] = []
        for (ordinal, local) in requests.enumerated() {
            guard local.configuration == first.configuration,
                  local.plan.fingerprint == first.plan.fingerprint,
                  local.arithmetic == first.arithmetic,
                  local.arithmeticEnvironmentSHA256 == first.arithmeticEnvironmentSHA256,
                  try canonicalJSONData(local.resource) == resource else {
                throw ProbeError("Resident solo changed its source, Plan, arithmetic or resources")
            }
            // Solo remains default-plan only, including direct callers.
            try QwenLongPrefillStageCut.validateBinding(nil, plan: local.plan)
            steps.append(.init(ordinal: ordinal, excludedWarmup: ordinal < warmupCount,
                requestID: local.request.request.requestID,
                recordedRequestFingerprint: local.request.fingerprint,
                promptFileSHA256: local.promptFileSHA256))
        }
        try QwenLongPrefillResidentRequestStep.validate(steps)
        return steps
    }
}
