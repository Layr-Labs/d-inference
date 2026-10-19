import CryptoKit
import Darwin
import DarkbloomClusterRuntime
import DarkbloomClusterSecurity
import Foundation
import Metal
import MLX
import MLXLLM

/// Private, launch-scoped authorization by the already authenticated member.
/// This document supplies measured/conservative evidence, never a workspace floor.
enum GLM5NextWorkerQualification {
    static let modelID = "qualification_glm5_next"
    static let domain = Data("darkbloom/glm-worker-qualification/v1\0".utf8)

    struct SignedDocument: Codable { let payload: Data; let signature: Data }
    struct File: Codable { let bytes: Int; let sha256: String }
    struct Payload: Codable {
        let version: Int
        let epoch: UUID
        let rank: Int
        let expiresUnixSeconds: Int64
        let repository: String
        let revision: String
        let files: [String: File]
        let artifactSHA256: String
        let cut: Int
        let profileID: String
        let maximumPromptTokens: Int
        let maximumChunkTokens: Int
        let maximumOutputTokens: Int
        let maximumContextTokens: Int
        let policy: String
        let storage: String
        let loadCapacityBytes: Int
        let requestCapacityBytes: Int
        let hostAllocationQuantum: Int
        let hostAllocationOverhead: Int
        let environment: Environment
        let workspaceEvidence: Data
    }
    struct Environment: Codable, Equatable {
        let binarySHA256: String
        let metallibSHA256: String
        let backend: String
        let allocator: String
        let os: String
        let deviceRegistryID: UInt64
        let deviceName: String
        let architecture: String
        let maximumBufferBytes: Int
        let recommendedWorkingSetBytes: UInt64
        let memoryBytes: Int
        let variableSHA256: [String: String]
    }
    struct Prepared {
        let descriptor: GLM5NextResidentDescriptor
        let resources: GLM5NextResidentResourceEnvelope
    }

    static func decode(_ data: Data, memberPublicKey: Data, epoch: UUID, rank: Int,
                       now: Int64) throws -> Payload {
        guard !data.isEmpty, data.count <= 256 << 10 else { throw invalid("Document exceeds bound") }
        let signed = try JSONDecoder().decode(SignedDocument.self, from: data)
        guard signed.payload.count <= 128 << 10, signed.signature.count == 64 else {
            throw invalid("Signed payload exceeds bound")
        }
        let key = try P256.Signing.PublicKey(x963Representation: memberPublicKey)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signed.signature)
        guard key.isValidSignature(signature, for: domain + signed.payload) else {
            throw invalid("Qualification signature does not match authenticated member")
        }
        let p = try JSONDecoder().decode(Payload.self, from: signed.payload)
        guard p.version == 1, p.epoch == epoch, p.rank == rank,
              now >= 0, p.expiresUnixSeconds > now, p.expiresUnixSeconds - now <= 3600,
              p.workspaceEvidence.count <= 65_536, !p.workspaceEvidence.isEmpty,
              p.hostAllocationQuantum > 0, p.hostAllocationQuantum <= 1 << 30,
              p.hostAllocationOverhead >= 0, p.hostAllocationOverhead <= 1 << 30,
              p.environment.backend == "jaccl", p.environment.allocator == "disableFreedBufferCache" else {
            throw invalid("Qualification scope, expiry or resource evidence is invalid")
        }
        return p
    }

    static func hostBound(_ bytes: Int, quantum: Int, overhead: Int) throws -> Int {
        guard bytes >= 0, quantum > 0, overhead >= 0 else { throw invalid("Invalid host bound") }
        let (padded, a) = bytes.addingReportingOverflow(quantum - 1)
        guard !a else { throw invalid("Host rounding overflow") }
        let (rounded, b) = (padded / quantum).multipliedReportingOverflow(by: quantum)
        let (total, c) = rounded.addingReportingOverflow(overhead)
        guard !b, !c, total >= bytes else { throw invalid("Host allocation overflow") }
        return total
    }

    static func prepare(path: String, configuration: WorkerConfiguration,
                        credential: ClusterDataPlaneCredential) throws -> Prepared {
        let load = configuration.load
        let deadline = configuration.startupDeadlineUptimeNanoseconds ?? load.deadlineUptimeNanoseconds
        let data = try WorkerCapabilityInput.read(path, maximumBytes: 256 << 10, deadline: deadline)
        let p = try decode(data, memberPublicKey: credential.memberIdentity.identityPublicKey,
            epoch: load.identity.membershipEpoch, rank: load.rank, now: Int64(Date().timeIntervalSince1970))
        guard credential.epoch == p.epoch, credential.rank == p.rank, p.cut == load.stageCut,
              p.artifactSHA256 == load.identity.artifactSHA256,
              p.environment.binarySHA256 == load.identity.peers[load.rank].buildSHA256 else {
            throw invalid("Qualification document differs from worker launch")
        }
        let environment = try LiveEnvironment(expected: p.environment, deadline: deadline)
        let digest = try hash(p.environment)
        let config = try WorkerCapabilityInput.read(load.modelDirectory.appendingPathComponent("config.json").path,
            maximumBytes: 32 << 20, deadline: deadline)
        guard SHA256.hash(data: config).map({ String(format: "%02x", $0) }).joined()
            == load.identity.configurationSHA256 else { throw invalid("Configuration differs from launch") }
        let storage: GLM5NextWeightInventory.Storage
        switch p.storage {
        case "nvfp4Hybrid": storage = .nvfp4Hybrid
        case "vontraQ4": storage = .vontraQ4
        default: throw invalid("Private GLM qualification requires an explicit packed storage format")
        }
        let policy: GLM5NextExecutionPolicy
        switch p.policy {
        case "serving_v1": policy = .serving
        case "reference_v1": policy = .reference
        default: throw invalid("Unknown GLM execution policy")
        }
        let descriptor = try GLM5NextResidentDescriptor(modelID: modelID,
            artifactIdentity: .init(repository: p.repository, revision: p.revision,
                files: p.files.mapValues { .init(bytes: $0.bytes, sha256: $0.sha256) }),
            artifactAggregateSHA256: p.artifactSHA256, configurationBytes: config, cut: p.cut,
            storage: storage, executionPolicy: policy, profileID: p.profileID,
            maximumPromptTokens: p.maximumPromptTokens, maximumChunkTokens: p.maximumChunkTokens,
            maximumOutputTokens: p.maximumOutputTokens, maximumContextTokens: p.maximumContextTokens)
        let inventory = try descriptor.inspectInventory(directory: load.modelDirectory)
        // The shared allowance is owned by the resident policy, never by this document.
        guard p.loadCapacityBytes >= GLM5NextResidentResourceEnvelope.metadataAllowanceBytes else {
            throw invalid("LOAD capacity cannot cover resident metadata")
        }
        let resources = try GLM5NextResidentResourceEnvelope(descriptor: descriptor, inventory: inventory,
            rank: p.rank, loadCapacityBytes: p.loadCapacityBytes, requestCapacityBytes: p.requestCapacityBytes,
            executionEnvironmentSHA256: digest, workspaceEvidence: p.workspaceEvidence,
            authenticateWorkspace: { guard $0 == p.workspaceEvidence else { throw invalid("Workspace changed") } },
            requireExecutionEnvironment: {
                guard $0 == digest, Int64(Date().timeIntervalSince1970) < p.expiresUnixSeconds else {
                    throw invalid("Qualification environment/authorization expired")
                }
                try environment.check()
            }, hostAllocationBound: { try hostBound($0, quantum: p.hostAllocationQuantum, overhead: p.hostAllocationOverhead) })
        return .init(descriptor: descriptor, resources: resources)
    }

    static func hash<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    private static func invalid(_ message: String) -> WorkerFailure { .invalid("GLM qualification: " + message) }

    final class LiveEnvironment {
        let expected: Environment
        let executable: String
        let library: String
        let stamps: [[Int64]]

        init(expected: Environment, deadline: UInt64) throws {
            self.expected = expected
            var capacity: UInt32 = 0
            _ = _NSGetExecutablePath(nil, &capacity)
            guard capacity > 1, capacity <= 4096 else { throw invalid("Executable path exceeds bound") }
            var bytes = [CChar](repeating: 0, count: Int(capacity))
            guard _NSGetExecutablePath(&bytes, &capacity) == 0 else { throw invalid("Cannot resolve executable") }
            executable = URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath().path
            library = URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent("mlx.metallib").path
            stamps = try [Self.stamp(executable), Self.stamp(library)]
            guard try WorkerCapabilityInput.hash(executable, maximumBytes: 1 << 30, deadline: deadline) == expected.binarySHA256,
                  try WorkerCapabilityInput.hash(library, maximumBytes: 1 << 30, deadline: deadline) == expected.metallibSHA256,
                  let device = MTLCopyAllDevices().first ?? MTLCreateSystemDefaultDevice() else {
                throw invalid("Executable/Metal library identity differs from measured environment")
            }
            // Require the first native library search location to be loadable;
            // fallback bundle/default libraries cannot silently satisfy this receipt.
            _ = try device.makeLibrary(URL: URL(fileURLWithPath: library))
            try check()
        }
        func check() throws {
            guard stamps == (try [Self.stamp(executable), Self.stamp(library)]),
                  let device = MTLCopyAllDevices().first ?? MTLCreateSystemDefaultDevice() else {
                throw invalid("Runtime files/device changed")
            }
            let info = GPU.deviceInfo()
            let variables = ProcessInfo.processInfo.environment.filter {
                $0.key.hasPrefix("MLX_") || $0.key.hasPrefix("DARKBLOOM_")
            }.mapValues { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
            guard expected.os == ProcessInfo.processInfo.operatingSystemVersionString,
                  expected.deviceRegistryID == device.registryID, expected.deviceName == device.name,
                  expected.architecture == info.architecture, expected.maximumBufferBytes == info.maxBufferSize,
                  expected.recommendedWorkingSetBytes == info.maxRecommendedWorkingSetSize,
                  expected.memoryBytes == info.memorySize, expected.variableSHA256 == variables else {
                throw invalid("Live backend/device/environment differs from workspace measurement")
            }
        }
        static func stamp(_ path: String) throws -> [Int64] {
            var value = stat()
            guard lstat(path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else {
                throw invalid("Runtime dependency is not a regular file")
            }
            return [Int64(value.st_dev), Int64(bitPattern: UInt64(value.st_ino)), Int64(value.st_size),
                Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec),
                Int64(value.st_ctimespec.tv_sec), Int64(value.st_ctimespec.tv_nsec)]
        }
    }
}
