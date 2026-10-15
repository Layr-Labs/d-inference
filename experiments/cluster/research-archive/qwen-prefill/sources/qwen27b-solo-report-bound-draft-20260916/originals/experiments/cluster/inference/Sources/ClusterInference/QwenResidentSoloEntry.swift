import Darwin
import Foundation
import MLX
import MLXLLM
import SoloDeviceExclusion

/// A dedicated process retains the exact shared solo exclusion through exit,
/// including failed model teardown. It never records or clears an owner journal.
private enum QwenResidentSoloDeviceScope {
    nonisolated(unsafe) static var held: ClusterDeviceExclusion?

    static func acquire() throws {
        guard Thread.isMainThread, held == nil,
              let entry = getpwuid(geteuid()), let home = entry.pointee.pw_dir else {
            throw ProbeError("Resident solo requires one process owner and its system user home")
        }
        let path = String(cString: home)
        guard path.hasPrefix("/"), path != "/" else { throw ProbeError("Invalid system user home") }
        held = try ClusterDeviceExclusion(directoryURL:
            URL(fileURLWithPath: path).appendingPathComponent(".darkbloom/cluster-device", isDirectory: true))
    }
}

private struct QwenResidentSoloAdmitted: Encodable {
    let kind = "qwen_resident_solo_generation_admitted"
    let schemaVersion = 1
    let verifiedModelLoaded = false
    let freshRequestStateCreated = false
    let canonicalDeviceExclusionHeld = true
    let warmupCount = 1
    let measuredCount: Int
    let requestedOutputCount = 128
    let maximumTokens = 8320
    let requestIDs: [UUID]
    let requestFingerprints: [String]
    let profile: QwenLayerStageGenerationProfile
    let promptFileSHA256: String
    let promptTokenIDsSHA256: String
    let expectedTokenFileSHA256: String
    let manifestSHA256: String
    let artifactSHA256: String
    let configurationSHA256: String
    let referencePlanSHA256: String
    let processLifetimeSeconds: Int
    let perRequestMaximumSeconds = 120
    let prefixReuse = false
    let mtpEnabled = false
    let externalTTFTMeasured = false
}

extension QwenResidentSoloCLI {
    func run() throws {
        // One alarm includes metadata, model load, all configured requests, teardown
        // and stdout. Native work cannot extend it with a new request.
        alarm(UInt32(reference.timeoutSeconds)); defer { alarm(0) }
        let priorSIGPIPE = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, priorSIGPIPE) }
        let began = DispatchTime.now().uptimeNanoseconds
        let end = began.addingReportingOverflow(UInt64(reference.timeoutSeconds) * 1_000_000_000)
        guard !end.overflow else { throw ProbeError("Resident solo absolute deadline overflow") }
        let input = try preflight(environment: ProcessInfo.processInfo.environment,
            read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
        try QwenResidentSoloDeviceScope.acquire()
        let resources = QwenFullGenerationReferenceResources(preflight: input.first, deadline: end.partialValue)
        try resources.check()
        let first = input.first.admission
        try publishSolo(QwenResidentSoloAdmitted(
            measuredCount: input.measuredCount, requestIDs: input.requests.map { $0.request.requestID },
            requestFingerprints: input.requests.map { $0.request.fingerprint }, profile: first.request.profile,
            promptFileSHA256: first.source.promptFileSHA256,
            promptTokenIDsSHA256: first.source.promptTokenIDsSHA256,
            expectedTokenFileSHA256: input.expectedTokenFileSHA256, manifestSHA256: input.first.manifestSHA256,
            artifactSHA256: first.source.resource.artifactAggregateSHA256,
            configurationSHA256: first.source.resource.configurationSHA256,
            referencePlanSHA256: first.source.plan.fingerprint,
            processLifetimeSeconds: reference.timeoutSeconds), check: resources.check)
        // Same BF16 target and cache policy as the matched resident cohort.
        // Setting this before construction does not create an MTP module.
        _qwen35MTPEnabled = false
        try MLX.withError { fault in
            Memory.cacheLimit = 0
            Memory.clearCache()
            try fault.check(); try resources.check()
            guard Memory.cacheMemory == 0 else { throw ProbeError("Solo allocator retained freed buffers before load") }
        }
        let report = try produceQwenResidentSoloCohort(directory: reference.directory,
            preflight: input, resources: resources,
            publishLoaded: { try publishSolo($0, check: resources.check) },
            publishRetired: { try publishSolo($0, check: resources.check) })
        try publishSolo(report, check: resources.check)
    }

    private func publishSolo<T: Encodable>(_ value: T, check: () throws -> Void) throws {
        try check()
        var data = try canonicalJSONData(value)
        // Only CPU timing/token/metadata values; no tensor row or state payload.
        guard !data.isEmpty, data.count <= 128 * 1024 else { throw ProbeError("Resident solo output exceeds its bound") }
        data.append(10); try check()
        try FileHandle.standardOutput.write(contentsOf: data)
        try check()
    }
}
