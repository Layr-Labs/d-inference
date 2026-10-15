import Foundation

/// Common, CPU-only intent for an entire bounded resident cohort. Actual loaded
/// storage and native precision remain the later per-request agreement's job.
struct QwenLongPrefillResidentCohortAgreement {
    static let maximumEncodedBytes = 16_384

    struct Entry: Encodable, Equatable {
        let ordinal: Int
        let epoch: String, requestID: String
        let recordedRequestFingerprint: String, promptFileSHA256: String
        let excludedWarmup: Bool
    }

    struct Descriptor: Encodable, Equatable {
        let schemaVersion = 1
        let kind = "qwen_long_prefill_resident_cohort_agreement"
        let initialEpoch: String
        let sourceConfigurationSHA256: String, expectedArtifactAggregateSHA256: String
        let planFingerprint: String, arithmeticEnvironmentSHA256: String
        let resourceAdmissionSHA256: String
        let profile: String, profileFingerprint: String
        let schedulingPolicy: String, logitsDType: String
        let transport: String, executionPath: String
        let requestCount: Int, warmupCount: Int
        let tracePathsDisabled = true
        let requests: [Entry]
    }

    let descriptor: Descriptor
    let fingerprint: String

    init(options: Options, requests: [QwenLongPrefillResidentRankRequest], warmupCount: Int) throws {
        try QwenLongPrefillResidentRankAdmission.validate(
            options: options, requests: requests, warmupCount: warmupCount)
        let first = requests[0]
        let entries = try requests.enumerated().map { ordinal, request in
            let identity = try request.identity
            return Entry(ordinal: ordinal, epoch: request.epoch,
                requestID: identity.requestID.uuidString.lowercased(),
                recordedRequestFingerprint: request.local.request.fingerprint,
                promptFileSHA256: request.local.promptFileSHA256,
                excludedWarmup: ordinal < warmupCount)
        }
        let descriptor = Descriptor(initialEpoch: first.epoch,
            sourceConfigurationSHA256: sha256(first.local.configuration),
            expectedArtifactAggregateSHA256: first.local.resource.expectedArtifactAggregateSHA256,
            planFingerprint: first.local.plan.fingerprint,
            arithmeticEnvironmentSHA256: first.local.arithmeticEnvironmentSHA256,
            resourceAdmissionSHA256: sha256(try canonicalJSONData(first.local.resource)),
            profile: first.local.request.request.profile.rawValue,
            profileFingerprint: first.local.request.request.profile.fingerprint,
            schedulingPolicy: options.stagePrefillPolicy!.rawValue,
            logitsDType: options.stageLogitsDType!, transport: options.transport.rawValue,
            executionPath: options.executionPath.rawValue,
            requestCount: requests.count, warmupCount: warmupCount, requests: entries)
        let bytes = try canonicalJSONData(descriptor)
        guard bytes.count <= Self.maximumEncodedBytes else {
            throw ProbeError("Resident cohort agreement exceeds its 16 KiB metadata bound")
        }
        self.descriptor = descriptor
        self.fingerprint = sha256(Data("qwen-long-prefill-resident-cohort-v1|".utf8) + bytes)
    }
}
