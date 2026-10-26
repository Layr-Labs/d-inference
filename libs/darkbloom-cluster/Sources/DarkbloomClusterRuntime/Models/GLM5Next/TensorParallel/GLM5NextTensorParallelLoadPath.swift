import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXNN

/// How a tensor-parallel GLM rank reads its weights. The product reads them
/// `prepared`; the others exist to compare (`DARKBLOOM_CLUSTER_LOAD_PATH`,
/// diagnosis only). Every path builds the same arrays, byte for byte
/// (`GLM5NextTensorParallelLoadDigest` shows it on the real model).
enum GLM5NextTensorParallelLoadPath: String, CaseIterable {
    /// One read of every file that checks its SHA-256 and copies the rank's
    /// bytes straight into their final buffers (`GLM5NextArtifactLoader
    /// .prepare`), through the file cache, so the files stay cached for the
    /// next load. Measured on an M5 Ultra: 14 GB/s from the SSD, 101 GB/s
    /// from the cache.
    case prepared
    /// The same pass, bypassing the file cache (cached pages are still used).
    case preparedUncached = "prepared-uncached"
    /// The per-tensor loader: every file hashed first, then each tensor read
    /// whole, copied into MLX, sliced and stacked (72-75 s per rank,
    /// 2026-10-21).
    case perTensor = "per-tensor"

    static let environmentKey = "DARKBLOOM_CLUSTER_LOAD_PATH"

    static func resolved(_ environment: [String: String]) throws -> Self {
        guard let raw = environment[environmentKey] else { return .prepared }
        guard let value = Self(rawValue: raw) else {
            throw ProbeError("\(environmentKey) must be one of "
                + allCases.map(\.rawValue).joined(separator: ", "))
        }
        return value
    }

    var verification: GLM5NextArtifactVerification {
        self == .perTensor ? .beforeLoad : .withPreparedPayload
    }
}

/// Where one rank's load time goes, as one line beside
/// `darkbloom-tensor-parallel-load-v1`: when the load began on the wall clock
/// (to line it up with the provider's timestamped log), then each phase's
/// nanoseconds, in order.
struct GLM5NextTensorParallelLoadPhases {
    private var phases: [(String, UInt64)] = []
    private var last: UInt64
    private let startedUnixMilliseconds: Int64

    init(since start: UInt64, startedUnixMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        last = start
        self.startedUnixMilliseconds = startedUnixMilliseconds
    }

    /// Work that ran beside the phases (another thread), after them on the line.
    private var notes: [(String, UInt64)] = []

    /// Closes the phase that ran since the previous mark.
    mutating func mark(_ name: String, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        phases.append((name, now >= last ? now - last : 0))
        last = now
    }

    mutating func note(_ name: String, _ nanoseconds: UInt64) { notes.append((name, nanoseconds)) }

    func line(rank: Int, path: GLM5NextTensorParallelLoadPath) -> String {
        "darkbloom-tensor-parallel-load-phases-v1 rank=\(rank) path=\(path.rawValue)"
            + " started_unix_ms=\(startedUnixMilliseconds) "
            + (phases + notes).map { "\($0.0)_ns=\($0.1)" }.joined(separator: " ")
    }
}

/// The SHA-256 of every array a loaded rank holds, for comparing load paths
/// and builds on the real model (`DARKBLOOM_CLUSTER_LOAD_DIGESTS`, diagnosis
/// only: `1` logs one aggregate line, `tensors` also a line per array). The
/// aggregate is the SHA-256 of the sorted `key shape dtype sha256` lines, so
/// two loads that hold the same bytes under the same names agree.
enum GLM5NextTensorParallelLoadDigest {
    static let environmentKey = "DARKBLOOM_CLUSTER_LOAD_DIGESTS"

    struct Entry: Equatable {
        let key: String
        let shape: [Int]
        let dtype: String
        let sha256: String
        var line: String { "\(key) \(shape.map(String.init).joined(separator: "x")) \(dtype) \(sha256)" }
    }

    /// Every parameter of `modules`, keyed `<module index>.<parameter path>`;
    /// hashed on all cores.
    static func entries(_ modules: [Module]) -> [Entry] {
        var named: [(String, MLXArray)] = []
        for (index, module) in modules.enumerated() {
            named += module.parameters().flattened().map { ("\(index).\($0.0)", $0.1) }
        }
        // The bytes are found on this thread (MLX), then only hashed in
        // parallel; the lock guards only the results.
        final class Work: @unchecked Sendable {
            let data: [Data]
            let lock = NSLock()
            var digests: [String]
            init(_ data: [Data]) { self.data = data; digests = Array(repeating: "", count: data.count) }
        }
        let work = Work(named.map { $0.1.asData(access: .noCopyIfContiguous).data })
        DispatchQueue.concurrentPerform(iterations: work.data.count) { index in
            let digest = SHA256.hash(data: work.data[index]).map { String(format: "%02x", $0) }.joined()
            work.lock.withLock { work.digests[index] = digest }
        }
        return named.indices.map {
            Entry(key: named[$0].0, shape: named[$0].1.shape, dtype: "\(named[$0].1.dtype)",
                  sha256: work.digests[$0])
        }
    }

    static func aggregate(_ entries: [Entry]) -> String {
        let text = entries.map(\.line).sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The lines to log, or none when the switch is off.
    static func lines(_ modules: [Module], rank: Int, path: GLM5NextTensorParallelLoadPath,
                      environment: [String: String]) -> [String] {
        guard let mode = environment[environmentKey], mode == "1" || mode == "tensors" else { return [] }
        let all = entries(modules)
        let bytes = all.reduce(0) { $0 + ($1.shape.reduce(1, *)) }
        var lines = ["darkbloom-tensor-parallel-load-digest-v1 rank=\(rank) path=\(path.rawValue)"
            + " arrays=\(all.count) elements=\(bytes) digest=\(aggregate(all))"]
        if mode == "tensors" {
            lines += all.sorted { $0.key < $1.key }.map {
                "darkbloom-tensor-parallel-load-tensor-v1 rank=\(rank) \($0.line)"
            }
        }
        return lines
    }
}

/// What a tensor-parallel rank works out from the checkpoint's metadata
/// before it loads: the inventory, the request charge and the bytes the
/// memory gate admits, and on the prepared path the artifact owner whose
/// single read then loads the shard. Pure CPU work on files and the
/// descriptor, so the load runs it on a thread of its own while the link
/// comes up (`GLM5NextTensorParallelBackground`). Measured on Ultra A, release
/// (`GLM5NextTensorParallelLoadSetupTimingTests`): inventory inspection 1.7 s,
/// the prepared owner's parse 1.7 s (the same headers and config again),
/// two envelopes and quotes 1.5 s, the shard's bytes 1.0 s; now the owner's
/// parse once, the two ranks' quotes at once, and byte-matched split axes.
struct GLM5NextTensorParallelLoadMetadata {
    let inventory: GLM5NextWeightInventory
    /// The prepared path's owner (metadata parsed, nothing hashed or read
    /// yet); nil on `per-tensor`, whose owner hashes every file and so is made
    /// after the memory gate, as before.
    let loader: GLM5NextArtifactLoader?
    var requestCharge: GLM5NextTensorParallelRequestCharge
    let requestReserve: Int
    let shardBytes: Int
    let mtpBytes: Int
    let visionBytes: Int
    let mediaCapacity: Int
    /// Nanoseconds of the inventory (or owner) and of the pricing, for the phases line.
    let inventoryNanoseconds: UInt64
    let resourcesNanoseconds: UInt64

    init(spec: GLM5NextRegisteredSpecification, descriptor: GLM5NextResidentDescriptor, directory: URL,
         rank: Int, buildSHA256: [String], path: GLM5NextTensorParallelLoadPath, roots: GLM5NextArtifactLoadRoots,
         pagedKV: Bool, maximumBufferBytes: Int) throws {
        let start = DispatchTime.now().uptimeNanoseconds
        if path == .perTensor {
            inventory = try descriptor.inspectInventory(directory: directory)
            loader = nil
        } else {
            // The owner the pass uses reads config, index and headers once, as
            // `inspectInventory` did: its inventory must be the registered one
            // (pinned fingerprint) built from the descriptor's own configuration,
            // and every file is hashed in the pass before anything is built.
            let owner = try GLM5NextArtifactLoader(directory: directory,
                expectedIdentity: descriptor.artifactIdentity, storage: descriptor.storage,
                constructionRoots: roots, executionPolicy: descriptor.executionPolicy,
                verification: path.verification)
            guard owner.inventory.configuration == descriptor.configuration,
                  owner.inventory.storage == descriptor.storage else {
                throw ProbeError("GLM inspected inventory differs from the explicit descriptor")
            }
            inventory = owner.inventory
            loader = owner
        }
        guard GLM5NextArtifactMetadata.fingerprint(inventory) == spec.inventorySHA256 else {
            throw ProbeError("GLM shard headers are not the registered inventory")
        }
        let priced = DispatchTime.now().uptimeNanoseconds
        inventoryNanoseconds = priced - start
        // Every rank is charged the request state of both pipeline stages: the
        // whole model's latent caches (replicated under TP) and all its KDA
        // state (charged whole, although a rank holds half its heads), so the
        // charge is never below the need. Beside it, one sealed sum's buffers
        // at the largest chunk: the float32 partial, its sealed frame, both
        // ranks' frames, the opened peer partial and the sum (six partials).
        //
        // A request is charged at its own context (`GLM5NextTensorParallelRequestCharge`):
        // the profile is the model's native context, and LOAD admits the memory
        // plan's request (`GLM5NextResidentDescriptor.memoryProfile`), as before.
        let profile = descriptor.profile
        let largestChunk = max(profile.maximumChunkTokens, GLM5NextTensorParallelResidentRuntime.bulkPrefillChunkTokens)
        let fixedRequestBytes = try QwenLongPrefillCheckedBytes.sum([
            try QwenLongPrefillCheckedBytes.product([6, largestChunk, descriptor.configuration.textConfig.hiddenSize, 4]),
            try QwenLongPrefillCheckedBytes.product([largestChunk / max(1, profile.maximumChunkTokens) - 1,
                GLM5NextServingResources.workspaceNativeBytes])])
        // Both ranks' envelopes, each with its quotation's own checks (load and
        // peak within the device), at once: they share nothing but the inputs.
        final class Envelopes: @unchecked Sendable {
            let lock = NSLock()
            var values: [Result<GLM5NextResidentResourceEnvelope, Error>?] = [nil, nil]
        }
        let envelopes = Envelopes()
        let inventory = inventory
        DispatchQueue.concurrentPerform(iterations: 2) { peer in
            let value = Result { () throws -> GLM5NextResidentResourceEnvelope in
                let resources = try GLM5NextServingResources.envelope(descriptor: descriptor, inventory: inventory,
                    rank: peer, buildSHA256: buildSHA256[peer])
                _ = try resources.quote(descriptor: descriptor, maximumBufferBytes: maximumBufferBytes,
                    allocationBound: QwenResidentResourceEnvironment.allocationBound)
                return resources
            }
            envelopes.lock.withLock { envelopes.values[peer] = value }
        }
        let quoted = try envelopes.values.map { try $0!.get() }
        var charge = try GLM5NextTensorParallelRequestCharge(descriptor: descriptor, envelopes: quoted,
            fixedBytes: fixedRequestBytes, speculativeDepth: GLM5NextTensorParallelResidentRuntime.mtpDepth,
            maximumBufferBytes: maximumBufferBytes, allocationBound: QwenResidentResourceEnvironment.allocationBound)
        // Pages are charged at FP32 rows until the pool, made with the stage, gives their own bytes.
        if pagedKV {
            charge.pagedHistory = .init(configuration: descriptor.configuration.textConfig,
                pageTokens: GLM5NextTensorParallelResidentRuntime.dsaPageTokens)
        }
        requestCharge = charge
        requestReserve = try charge.bytes(contextTokens: descriptor.memoryProfile.maximumContextTokens)
        shardBytes = try GLM5NextTensorParallelResidentRuntime.shardBytes(inventory)
        // Every rank holds the NextN layer whole: its loader never shards, so
        // its bytes are the stored ones (`GLM5NextTensorShard.splitAxis` has
        // no layer bound and would wrongly halve some of them).
        mtpBytes = GLM5NextTensorParallelResidentRuntime.mtpDepth > 0 ? inventory.bytes(in: .mtp) : 0
        // Rank 0 holds the vision tower; a media request adds at most
        // `capacityBytes` to a rank's request charge (its readiness capacity).
        visionBytes = rank == 0 ? inventory.bytes(in: .vision) : 0
        mediaCapacity = try GLM5NextTensorParallelMedia.capacityBytes(rank: rank,
            configuration: descriptor.configuration)
        resourcesNanoseconds = DispatchTime.now().uptimeNanoseconds - priced
    }
}

/// One computation on a thread of its own, joined once by the thread that
/// started it. A load that fails before joining leaves it to finish alone.
final class GLM5NextTensorParallelBackground<Value>: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<Value, Error>?
    let startedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    private(set) var finishedUptimeNanoseconds: UInt64 = 0

    init(_ work: @escaping () throws -> Value) {
        Thread.detachNewThread { [self] in
            result = Result { try work() }
            finishedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            done.signal()
        }
    }

    /// Waits for the result (the semaphore orders the thread's writes before this read).
    func join() throws -> Value {
        done.wait()
        return try result!.get()
    }
}
