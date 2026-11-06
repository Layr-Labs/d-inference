import Darwin
import Foundation

private struct QwenFullGenerationReferenceAdmitted: Encodable {
    let kind = "qwen_full_generation_reference_admitted"
    let schemaVersion = 1
    let verifiedModelLoaded = false
    let freshRequestStateCreated = false
    let correctnessOnly = true
    let throughputMeasurementValid = false
    let requestID: UUID
    let requestFingerprint: String
    let profile: QwenLayerStageGenerationProfile
    let promptFileSHA256: String
    let promptTokenIDsSHA256: String
    let manifestSHA256: String
    let artifactSHA256: String
    let configurationSHA256: String
    let planSHA256: String
    let requestedOutputCount: Int
    let maximumTokens: Int
    let stopTokenIDs: [Int]
}

extension QwenFullGenerationReferenceCLI {
    func run() throws {
        // The process alarm covers metadata, model initialization and final
        // output, including native calls that cannot poll cooperative checks.
        alarm(UInt32(timeoutSeconds)); defer { alarm(0) }
        let start = DispatchTime.now().uptimeNanoseconds
        let end = start.addingReportingOverflow(UInt64(timeoutSeconds) * 1_000_000_000)
        guard !end.overflow else { throw ProbeError("Full reference deadline overflow") }
        let preflight = try preflight(environment: ProcessInfo.processInfo.environment,
            read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
        let resources = QwenFullGenerationReferenceResources(preflight: preflight, deadline: end.partialValue)
        try resources.check()
        let admission = preflight.admission
        try publish(QwenFullGenerationReferenceAdmitted(requestID: requestID,
            requestFingerprint: admission.request.fingerprint, profile: admission.request.profile,
            promptFileSHA256: admission.source.promptFileSHA256,
            promptTokenIDsSHA256: admission.source.promptTokenIDsSHA256,
            manifestSHA256: preflight.manifestSHA256,
            artifactSHA256: admission.source.resource.expectedArtifactAggregateSHA256,
            configurationSHA256: admission.source.resource.sourceConfigurationSHA256,
            planSHA256: admission.source.plan.fingerprint, requestedOutputCount: outputCount,
            maximumTokens: admission.request.maximumTokens, stopTokenIDs: stopTokenIDs.sorted()), check: resources.check)
        let result = try produceQwenFullGenerationReference(directory: directory,
            preflight: preflight, resources: resources)
        try publish(result, check: resources.check)
    }

    private func publish<T: Encodable>(_ value: T, check: () throws -> Void) throws {
        try check()
        var data = try canonicalJSONData(value)
        guard !data.isEmpty, data.count <= 16 * 1_048_576 else { throw ProbeError("Full reference record exceeds its 16 MiB output cap") }
        data.append(10)
        try check()
        try FileHandle.standardOutput.write(contentsOf: data)
        try check()
    }
}
