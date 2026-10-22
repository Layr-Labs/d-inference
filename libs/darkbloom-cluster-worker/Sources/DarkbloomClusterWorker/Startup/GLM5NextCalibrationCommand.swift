import CryptoKit
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import DarkbloomClusterRuntime
import MLX
import MLXLLM
import Darwin
import Foundation

/// Separate entry point and signature domain: a calibration authorization is
/// never a serving qualification document. No READY/control-token publication.
enum GLM5NextCalibrationCommand {
    static let domain = Data("darkbloom/glm-worker-calibration/v1\0".utf8)
    struct Payload: Codable {
        let selection: GLM5NextWorkerQualification.Payload
        let authorization: GLM5NextCalibration.Authorization
        let binding: GLM5NextCalibration.Binding
    }

    static func decode(_ data: Data, memberPublicKey: Data, configuration: WorkerConfiguration,
                       now: Int64) throws -> Payload {
        guard data.count > 0, data.count <= 256 << 10,
              configuration.glmQualificationDocument != nil,
              configuration.qualificationSwitchesPermitted, configuration.dataPlaneEncrypted,
              !configuration.keepWarm, configuration.generationMode == .pipeline,
              configuration.speculativeTerms == nil, !configuration.prefixSSDKeyOnInput,
              configuration.evidenceDirectory == nil else { throw invalid("Unsupported calibration mode") }
        let signed = try JSONDecoder().decode(GLM5NextWorkerQualification.SignedDocument.self, from: data)
        guard !signed.payload.isEmpty, signed.payload.count <= 128 << 10, signed.signature.count == 64 else {
            throw invalid("Calibration document exceeds bound")
        }
        let key = try P256.Signing.PublicKey(x963Representation: memberPublicKey)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signed.signature)
        guard key.isValidSignature(signature, for: domain + signed.payload) else {
            throw invalid("Calibration signature differs from authenticated member")
        }
        let result = try JSONDecoder().decode(Payload.self, from: signed.payload)
        // Compare all object key sets recursively: Binding Codable itself accepts
        // unknown keys, but this signed finite-experiment wire is closed.
        try requireClosedPayload(signed.payload, decoded: result)
        let p = result.selection, load = configuration.load
        let profile = result.binding.profile
        guard profile.id == p.profileID, profile.vocabularySize > 0,
              profile.vocabularySize <= Int(Int32.max),
              profile.maximumPromptTokens == p.maximumPromptTokens,
              profile.maximumOutputTokens == p.maximumOutputTokens,
              profile.maximumChunkTokens == p.maximumChunkTokens,
              profile.maximumContextTokens == p.maximumContextTokens,
              result.authorization.promptTokenIDs.allSatisfy({ $0 >= 0 && $0 < profile.vocabularySize }) else {
            throw invalid("Calibration binding profile differs from selection")
        }
        try result.authorization.validate()
        try GLM5NextCalibration.requirePinnedSelection(repository: p.repository, revision: p.revision,
            aggregate: p.artifactSHA256, configurationSHA256: p.files["config.json"]?.sha256,
            indexSHA256: p.files["model.safetensors.index.json"]?.sha256)
        guard p.version == 1, p.epoch == load.identity.membershipEpoch, p.rank == load.rank,
              now >= 0, p.expiresUnixSeconds > now, p.expiresUnixSeconds - now <= 3600,
              p.storage == "nvfp4Hybrid", p.policy == "serving_v1",
              p.artifactSHA256 == load.identity.artifactSHA256, p.cut == load.stageCut,
              p.files["config.json"]?.sha256 == load.identity.configurationSHA256,
              p.environment.binarySHA256 == load.identity.peers[load.rank].buildSHA256,
              p.environment.backend == "jaccl", p.environment.allocator == "disableFreedBufferCache",
              p.workspaceEvidence.isEmpty,
              p.loadCapacityBytes > 0, p.requestCapacityBytes > 0,
              p.requestCapacityBytes <= p.loadCapacityBytes,
              p.loadCapacityBytes <= result.authorization.nativeHardCapBytes + result.authorization.hostBudgetBytes,
              result.authorization.nativeHardCapBytes + result.authorization.hostBudgetBytes <= p.environment.memoryBytes,
              result.authorization.osHeadroomBytes < p.environment.memoryBytes
                - result.authorization.nativeHardCapBytes - result.authorization.hostBudgetBytes,
              p.hostAllocationQuantum > 0, p.hostAllocationQuantum <= 1 << 30,
              p.hostAllocationOverhead >= 0, p.hostAllocationOverhead <= 1 << 30,
              p.maximumPromptTokens > 0, p.maximumPromptTokens <= 2048,
              p.maximumChunkTokens > 0, p.maximumChunkTokens <= p.maximumPromptTokens,
              p.maximumOutputTokens > 0, p.maximumOutputTokens <= 16,
              p.maximumContextTokens >= p.maximumPromptTokens + p.maximumOutputTokens,
              p.maximumContextTokens <= 2064,
              result.authorization.promptTokenIDs.count <= p.maximumPromptTokens,
              result.authorization.outputCount <= p.maximumOutputTokens,
              result.authorization.chunkSize <= p.maximumChunkTokens else {
            throw invalid("Calibration authority, capacity, artifact or cold-text scope differs from launch")
        }
        return result
    }

    /// Metadata-only equality gate shared with regressions; no plan duplication,
    /// native model allocation, bootstrap attachment or LOAD before this check.
    static func requireBinding(_ expected: GLM5NextCalibration.Binding,
                               descriptor: GLM5NextResidentDescriptor,
                               inventory: GLM5NextWeightInventory) throws {
        guard try GLM5NextCalibration.binding(descriptor: descriptor, inventory: inventory) == expected else {
            throw invalid("Calibration binding differs from actual descriptor and inventory")
        }
    }

    private static func requireClosedPayload(_ bytes: Data, decoded: Payload) throws {
        func sameKeys(_ a: Any, _ b: Any) -> Bool {
            if let a = a as? [String: Any], let b = b as? [String: Any] {
                return Set(a.keys) == Set(b.keys) && a.allSatisfy { key, value in
                    guard let other = b[key] else { return false }
                    return sameKeys(value, other)
                }
            }
            if let a = a as? [Any], let b = b as? [Any] {
                return a.count == b.count && zip(a, b).allSatisfy { sameKeys($0.0, $0.1) }
            }
            return !(a is [String: Any]) && !(b is [String: Any]) && !(a is [Any]) && !(b is [Any])
        }
        guard try sameKeys(JSONSerialization.jsonObject(with: bytes),
                           JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded))) else {
            throw invalid("Missing or unknown calibration payload fields")
        }
    }

    static func run(arguments: [String]) throws {
        let configuration = try WorkerConfiguration(arguments: arguments,
            now: DispatchTime.now().uptimeNanoseconds)
        guard let path = configuration.glmQualificationDocument,
              configuration.dataPlaneEncrypted else { throw invalid("Calibration requires authenticated launch") }
        let deadline = min(configuration.load.deadlineUptimeNanoseconds,
                           configuration.startupDeadlineUptimeNanoseconds ?? UInt64.max)
        let credential = try WorkerDataPlaneTrust.read(descriptor: STDIN_FILENO, until: deadline,
            epoch: configuration.load.identity.membershipEpoch, rank: configuration.load.rank)
        let bytes = try WorkerCapabilityInput.read(path, maximumBytes: 256 << 10, deadline: deadline)
        let payload = try decode(bytes, memberPublicKey: credential.memberIdentity.identityPublicKey,
                       configuration: configuration, now: Int64(Date().timeIntervalSince1970))
        signal(SIGPIPE, SIG_IGN)
        ProcessNativeMemoryRelease.installForForcedExit()
        try ProcessForcedExit.routeTerminationSignals()
        try ProcessDeadline.arm(lease: configuration.lease, status: 124)
        // Independent experiment deadline: rank renewals cannot extend it, and
        // it is never disarmed by READY. Authentication used the shorter deadline.
        let experimentDeadline = configuration.startupDeadlineUptimeNanoseconds ?? deadline
        _ = try WorkerStartupDeadline.arm(uptimeNanoseconds: experimentDeadline)
        try GLM5NextCalibrationNativeCap.install(bytes: payload.authorization.nativeHardCapBytes)
        try execute(payload, configuration: configuration, credential: credential, deadline: experimentDeadline)
    }

    /// Complete native path behind the enforcing-backend gate. No serving
    /// coordinator.run call: the only stdout result is an unqualified report.
    private static func execute(_ payload: Payload, configuration: WorkerConfiguration,
                                credential: ClusterDataPlaneCredential, deadline: UInt64) throws {
        let pipes = try WorkerPipes(input: STDIN_FILENO, output: STDOUT_FILENO, lease: configuration.lease)
        let coordinator = WorkerCoordinator(pipes: pipes, membershipEpoch: configuration.load.identity.membershipEpoch,
            keepWarm: false, exitHooks: .forcedExit, renewal: { _ in })
        coordinator.startReading()
        let p = payload.selection
        let environment = try GLM5NextWorkerQualification.LiveEnvironment(expected: p.environment, deadline: deadline)
        let digest = try GLM5NextWorkerQualification.hash(p.environment)
        let config = try WorkerCapabilityInput.read(configuration.load.modelDirectory.appendingPathComponent("config.json").path,
            maximumBytes: 32 << 20, deadline: deadline)
        let descriptor = try GLM5NextResidentDescriptor(modelID: GLM5NextWorkerQualification.modelID,
            artifactIdentity: .init(repository: p.repository, revision: p.revision,
                files: p.files.mapValues { .init(bytes: $0.bytes, sha256: $0.sha256) }),
            artifactAggregateSHA256: p.artifactSHA256, configurationBytes: config, cut: p.cut,
            storage: .nvfp4Hybrid, executionPolicy: .serving, profileID: p.profileID,
            maximumPromptTokens: p.maximumPromptTokens, maximumChunkTokens: p.maximumChunkTokens,
            maximumOutputTokens: p.maximumOutputTokens, maximumContextTokens: p.maximumContextTokens)
        let inventory = try descriptor.inspectInventory(directory: configuration.load.modelDirectory)
        try GLM5NextCalibration.requirePinnedInventory(inventory)
        try requireBinding(payload.binding, descriptor: descriptor, inventory: inventory)
        let plan = try GLM5NextCalibration.plan(descriptor: descriptor, inventory: inventory, rank: p.rank,
            authorization: payload.authorization, authorizationSHA256: try GLM5NextWorkerQualification.hash(payload),
            executionEnvironmentSHA256: digest, authenticate: {}, requireEnvironment: { actual in
                try pipes.check()
                guard actual == digest, Int64(Date().timeIntervalSince1970) < p.expiresUnixSeconds else {
                    throw invalid("Calibration environment authorization expired")
                }
                try environment.check()
            }, maximumBufferBytes: GPU.deviceInfo().maxBufferSize,
            allocationBound: { try Memory.allocationFootprintUpperBound(byteCount: $0) },
            hostAllocationBound: { try GLM5NextWorkerQualification.hostBound($0,
                quantum: p.hostAllocationQuantum, overhead: p.hostAllocationOverhead) })
        guard plan.quote.loadCapacityBytes <= p.loadCapacityBytes,
              plan.quote.requestCapacityBytes <= p.requestCapacityBytes else {
            throw invalid("Actual quotation exceeds independently authorized capacities")
        }
        let attachment = try configuration.bootstrap?.attach(epoch: p.epoch, rank: p.rank)
        if let attachment { retainedAttachments.hold(attachment) }
        let report = try GLM5NextCalibration.run(plan: plan, configuration: configuration.load, credential: credential,
            requireNativeCap: { try GLM5NextCalibrationNativeCap.requireInstalled(bytes: $0) }, observeHost: hostObservation)
        try JACCLOwnerBootstrap.requireConsumedIfInstalled()
        let encoded = try JSONEncoder().encode(report)
        guard encoded.count <= 65_536 else { throw invalid("Calibration report exceeds bound") }
        FileHandle.standardOutput.write(encoded + Data([10]))
        withExtendedLifetime(coordinator) {}
    }

    private static func hostObservation() throws -> GLM5NextCalibration.HostObservation {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var malloc = malloc_statistics_t()
        malloc_zone_statistics(nil, &malloc)
        guard status == KERN_SUCCESS, info.phys_footprint <= UInt64(Int.max),
              malloc.size_in_use <= Int.max else { throw invalid("Cannot observe host memory") }
        return .init(mallocBytes: Int(malloc.size_in_use), processFootprintBytes: Int(info.phys_footprint))
    }
    private static let retainedAttachments = Attachments()
    private final class Attachments: @unchecked Sendable {
        let lock = NSLock()
        var values: [WorkerOwnerAttachment] = []
        func hold(_ value: WorkerOwnerAttachment) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    }
    private static func invalid(_ message: String) -> WorkerFailure {
        .invalid("GLM calibration: " + message)
    }
}
