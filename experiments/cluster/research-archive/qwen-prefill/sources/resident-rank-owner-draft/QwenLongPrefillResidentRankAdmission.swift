import Foundation

/// Retained CPU admission for one fresh request. The existing admission owns
/// the exact prompt bytes/history contract; no file is reread by the cohort.
struct QwenLongPrefillResidentRankRequest {
    let epoch: String
    let local: QwenRegistered9BLongPrefillReferenceAdmission

    var identity: QwenLayerStageResidentRequestIdentity {
        get throws {
            let id = try QwenLayerStageRankAdmission.requestID(epoch: epoch)
            guard local.request.request.requestID == id else {
                throw ProbeError("Resident request UUID differs from its wire epoch")
            }
            return .init(requestID: id, epoch: id, recordedRequestFingerprint: local.request.fingerprint)
        }
    }
}

enum QwenLongPrefillResidentRankAdmission {
    static func validate(options: Options, requests: [QwenLongPrefillResidentRankRequest],
                         warmupCount: Int) throws {
        try QwenLongPrefillRankAdmission.validateOptions(options)
        guard options.prefillPhaseTraceFile == nil, options.prefillOwnerTraceFile == nil,
              (1...QwenLayerStageResidentLifecycle.maximumCohortRequests).contains(requests.count),
              (0..<requests.count).contains(warmupCount), let first = requests.first,
              first.epoch == options.epoch,
              first.local.resource.expectedArtifactAggregateSHA256 == options.expectedArtifactAggregateSHA256,
              first.local.promptFileSHA256 == options.longPromptSHA256 else {
            throw ProbeError("Resident cohort requires bounded requests, a measured request and the pinned initial input")
        }
        let resource = try canonicalJSONData(first.local.resource)
        var epochs = Set<UUID>(), ids = Set<UUID>()
        for request in requests {
            let identity = try request.identity
            guard epochs.insert(identity.epoch).inserted, ids.insert(identity.requestID).inserted,
                  request.local.configuration == first.local.configuration,
                  request.local.plan.fingerprint == first.local.plan.fingerprint,
                  request.local.arithmetic == first.local.arithmetic,
                  request.local.arithmeticEnvironmentSHA256 == first.local.arithmeticEnvironmentSHA256,
                  try canonicalJSONData(request.local.resource) == resource else {
                throw ProbeError("Resident cohort changed its source, Plan, arithmetic, resources or reused an identity")
            }
            try QwenLongPrefillStageCut.validateBinding(options.stageCut, plan: request.local.plan)
        }
    }
}
