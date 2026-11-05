import Darwin
import Foundation
import MLX
import MLXLLM

/// Refusal/observation hooks cannot fabricate a successful native evaluation or
/// fence. Production uses the empty value; fixtures can fail a precise boundary.
struct GLM5NextResidentLoadHooks {
    var beforeVerification: (() throws -> Void)?
    var beforeTensorRead: ((String, Int) throws -> Void)?
    var beforeEvaluation: (([MLXArray]) throws -> Void)?
    var beforeCleanupFence: (() throws -> Void)?
}

/// Caller-serialized resident ownership, not worker registration or request
/// admission. Create before loading and retain after any failed load/close.
final class GLM5NextResidentStage {
    /// Keep this handle through all work and derived references using `value`.
    /// It keeps the resident owner alive; dropping it is not a cleanup fence.
    final class Borrow<Component: AnyObject> {
        let value: Component
        private let resident: GLM5NextResidentStage
        fileprivate init(_ value: Component, resident: GLM5NextResidentStage) {
            self.value = value; self.resident = resident
        }
    }

    private final class WeakObject {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }

    enum Phase: Equatable { case prepared, loading, loaded, failed, closed }
    struct Receipt {
        let artifactIdentity: GLM5NextArtifactIdentity
        let source: QwenLayerStageWireSourceIdentity
        let stageFingerprint: String
        let numericalPolicySHA256: String
        let resources: GLM5NextStageLoadResources.Summary
        let selectedPayloadTensorCount: Int
        let selectedPayloadBytes: Int
        let selectedNamesSHA256: String
        let stageParameterLayoutSHA256: String
        let mtpParameterLayoutSHA256: String?
        let reservedBytes: Int
        let capacityLimitBytes: Int
        let executionStateReserveBytes: Int
        let workspaceReserveBytes: Int
        let admission: QwenDenseStageLoadAdmission
        let nativeObservation: QwenDenseStageLoadNativeObservation
    }

    let resources: GLM5NextStageLoadResources
    private(set) var phase = Phase.prepared
    private(set) var receipt: Receipt?
    /// SDK arrays may create views whose native backing outlives every original
    /// Swift wrapper. Once exposed, only process exit proves complete retirement.
    /// A successful close still joins work and drops our roots, but never reopens
    /// this process's resident lease.
    private(set) var requiresProcessExit = false
    private let directory: URL
    private let expectedIdentity: GLM5NextArtifactIdentity
    private let artifactAggregateSHA256: String
    private var inventory: GLM5NextWeightInventory?
    private let inventorySHA256: String
    private let executionPolicy: GLM5NextExecutionPolicy
    private let hooks: GLM5NextResidentLoadHooks
    private let gate: GLM5NextStageLoadGate
    private lazy var roots = GLM5NextArtifactLoadRoots(beforeEvaluation: { [weak self] arrays in
        guard let self else { throw ProbeError("GLM resident owner has retired") }
        try gate.requireLive()
        if let observe = hooks.beforeEvaluation {
            // A hook can retain a derived view even when it throws. Mark the
            // exposure before calling it; fences cannot prove that view died.
            requiresProcessExit = true
            try observe(arrays)
        }
        try gate.requireOperation()
    })
    private let operation = NSLock()
    private let processLease: QwenResidentProcessLease
    private var ownsProcessLease = false
    private var loader: GLM5NextArtifactLoader?
    private var stage: GLM5NextStageBinding?
    private var mtp: GLM5NextMTP?
    private var vision: GLM5NextStageVision?
    private weak var loadedVision: GLM5NextStageVision?
    private weak var loadedModel: GLM5NextTextStage?
    private weak var loadedMTP: GLM5NextMTP?
    private var borrowHandles: [WeakObject] = []
    private var borrowedComponents: [ObjectIdentifier: WeakObject] = [:]

    var retainedArrayCount: Int { roots.retainedArrayCount }
    var retainedOwnerCount: Int { roots.retainedOwnerCount }

    /// Only bounded config/index/header reads occur here. Capacity refusal thus
    /// precedes even the SDK's streamed payload-hash pass, as well as tensor IO.
    /// No guessed context or workspace floor is supplied by this foundation.
    init(directory: URL, expectedIdentity: GLM5NextArtifactIdentity,
         artifactAggregateSHA256: String, storage: GLM5NextWeightInventory.Storage,
         stageIndex: Int, cut: Int, includeMTP: Bool, executionPolicy: GLM5NextExecutionPolicy,
         capacityLimitBytes: Int, executionStateReserveBytes: Int, workspaceReserveBytes: Int,
         hooks: GLM5NextResidentLoadHooks = .init(),
         processLease: QwenResidentProcessLease = .shared, includeVision: Bool = false) throws {
        guard qwenStageWireIsSHA256(artifactAggregateSHA256) else {
            throw ProbeError("GLM resident source requires its trusted artifact aggregate")
        }
        let inventory = try Self.inspect(directory: directory, identity: expectedIdentity, storage: storage)
        let resources = try GLM5NextStageLoadResources(inventory: inventory, stageIndex: stageIndex,
            cut: cut, includeMTP: includeMTP, executionPolicy: executionPolicy,
            // Header admission and SDK verification coexist while loading;
            // selected-name/bound/read ledgers have their own bounded share.
            metadataAllowanceBytes: GLM5NextResidentResourceEnvelope.metadataAllowanceBytes,
            maximumBufferBytes: GPU.deviceInfo().maxBufferSize,
            allocationBound: { try Memory.allocationFootprintUpperBound(byteCount: $0) }, includeVision: includeVision)
        let gate = try GLM5NextStageLoadGate(resources: resources, capacityLimitBytes: capacityLimitBytes,
            executionStateReserveBytes: executionStateReserveBytes, workspaceReserveBytes: workspaceReserveBytes)
        self.directory = directory; self.expectedIdentity = expectedIdentity
        self.artifactAggregateSHA256 = artifactAggregateSHA256; self.inventory = inventory
        inventorySHA256 = GLM5NextArtifactMetadata.fingerprint(inventory)
        self.executionPolicy = executionPolicy; self.hooks = hooks
        self.resources = resources; self.gate = gate; self.processLease = processLease
    }

    func load(check: @escaping () throws -> Void) throws {
        guard operation.try() else { throw ProbeError("GLM resident operation is already active") }
        defer { operation.unlock() }
        guard phase == .prepared, let inventory else { throw ProbeError("GLM resident load is single-use") }
        // A failure to acquire somebody else's lease does not claim or release it.
        try processLease.acquire()
        ownsProcessLease = true
        phase = .loading
        do {
            try gate.beginOperation(check: check)
            defer { gate.endOperation() }
            try check()
            try QwenResidentResourceEnvironment.requirePower()
            // Preparation can outlive a previous resident owner. Refuse stale
            // allocator bounds rather than silently reuse its admission terms.
            let current = try GLM5NextStageLoadResources(inventory: inventory,
                stageIndex: resources.summary.stageIndex, cut: resources.summary.cut,
                includeMTP: resources.summary.includesMTP, executionPolicy: executionPolicy,
                metadataAllowanceBytes: resources.summary.metadataAllowanceBytes,
                maximumBufferBytes: GPU.deviceInfo().maxBufferSize,
                allocationBound: { try Memory.allocationFootprintUpperBound(byteCount: $0) }, includeVision: resources.summary.includesVision)
            guard current.summary == resources.summary,
                  current.selected.allSatisfy({ name, value in
                      resources.selected[name]?.allocationBound == value.allocationBound
                  }) else { throw ProbeError("GLM allocator bounds changed after metadata admission") }
            try gate.requireLive()
            try hooks.beforeVerification?()
            let loader = try GLM5NextArtifactLoader(directory: directory, expectedIdentity: expectedIdentity,
                storage: inventory.storage, constructionRoots: roots, executionPolicy: executionPolicy)
            self.loader = loader
            guard loader.configuration == inventory.configuration,
                  GLM5NextArtifactMetadata.fingerprint(loader.inventory) == inventorySHA256 else {
                throw ProbeError("GLM verified owner differs from admitted header inventory")
            }
            try check(); try gate.requireLive()
            let summary = resources.summary
            let contract = try GLM5NextStageContract(loader: loader,
                artifactAggregateSHA256: artifactAggregateSHA256,
                storageCommitmentSHA256: resources.storageCommitmentSHA256,
                cut: summary.cut, loadMTPEmbedding: summary.includesMTP)
            func beforeRead(_ name: String, _ bytes: Int) throws {
                try gate.beforeRead(name, bytes: bytes, check: check)
                try hooks.beforeTensorRead?(name, bytes)
            }
            let binding = try contract.loadStage(using: loader, stageIndex: summary.stageIndex,
                beforeTensorRead: beforeRead)
            stage = binding; loadedModel = binding.model
            if summary.includesMTP && summary.stageIndex == 1 {
                let head = try loader.loadMTP(stage: binding.model, beforeTensorRead: beforeRead)
                mtp = head; loadedMTP = head
            }
            if summary.includesVision && summary.stageIndex == 0 {
                let tower = try MLX.withError { errors in
                    try GLM5NextStageVision(loader: loader, roots: roots, beforeRead: beforeRead,
                        check: { try errors.check(); try check(); try self.gate.requireLive(); try errors.check() })
                }
                vision = tower; loadedVision = tower
            }
            let unresolved = Set(GLM5NextWeightInventory.Part.allCases.flatMap { loader.unresolved(in: $0) })
            let consumed = Set(inventory.entries.keys).subtracting(unresolved)
            guard consumed == Set(resources.selected.keys),
                  Set(gate.requestedNames) == consumed else {
                throw ProbeError("GLM verified payload reads differ from selected stage ownership")
            }
            try loader.verifyUnchanged()
            binding.model.freeze(); mtp?.freeze()
            try MLX.withError { errors in
                let arrays = binding.model.parameters().flattened().map(\.1)
                    + (mtp?.parameters().flattened().map(\.1) ?? [])
                try roots.evaluate(arrays)
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                try errors.check(); try check()
            }
            try gate.finish()
            guard let admission = gate.lastAdmission, let native = gate.lastNativeObservation else {
                throw ProbeError("GLM load lacks live admission evidence")
            }
            receipt = .init(artifactIdentity: loader.identity,
                source: contract.source, stageFingerprint: contract.stageFingerprints[summary.stageIndex],
                numericalPolicySHA256: contract.numericalPolicySHA256, resources: summary,
                selectedPayloadTensorCount: consumed.count, selectedPayloadBytes: gate.requestedBytes,
                selectedNamesSHA256: resources.selectedNamesSHA256,
                stageParameterLayoutSHA256: modelParameterLayout(binding.model),
                mtpParameterLayoutSHA256: mtp.map { modelParameterLayout($0) },
                reservedBytes: gate.reservedBytes, capacityLimitBytes: gate.capacityLimitBytes,
                executionStateReserveBytes: gate.executionStateReserveBytes,
                workspaceReserveBytes: gate.workspaceReserveBytes,
                admission: admission, nativeObservation: native)
            // The final successful fence permits retiring construction aliases.
            // Keep the models themselves until distributed/local close is proven.
            roots.releaseAfterConfirmedFence()
            roots.retainOwner(binding.model)
            if let mtp { roots.retainOwner(mtp) }
            if let vision { roots.retainOwner(vision) }
            self.inventory = nil
            phase = .loaded
        } catch {
            phase = .failed
            // No cleanup, release of admission, retry, or replacement on failure.
            throw error
        }
    }

    /// Select a component or construct a session that owns its model. The only
    /// escaping reference from `select` must be its result. Borrow each separate
    /// component explicitly; retain its handle through derived arrays/native work.
    /// Exposure permanently closes replacement admission in this process, even
    /// if selection throws: a closure can retain a view before throwing.
    func borrowComponent<Component: AnyObject>(
        _ select: (GLM5NextStageBinding, GLM5NextMTP?) throws -> Component
    ) throws -> Borrow<Component> {
        guard operation.try() else { throw ProbeError("GLM resident operation is already active") }
        defer { operation.unlock() }
        guard phase == .loaded, let stage else { throw ProbeError("GLM resident stage is not loaded") }
        requiresProcessExit = true
        let component = try select(stage, mtp)
        let handle = Borrow(component, resident: self)
        borrowHandles.removeAll { $0.value == nil }
        borrowedComponents = borrowedComponents.filter { $0.value.value != nil }
        borrowHandles.append(WeakObject(handle))
        borrowedComponents[ObjectIdentifier(component)] = WeakObject(component)
        return handle
    }

    func borrowVision() throws -> Borrow<GLM5NextStageVision> {
        try borrowComponent { _, _ in
            guard let vision = self.vision else { throw ProbeError("GLM rank has no admitted vision tower") }
            return vision
        }
    }

    /// The caller retires all sessions/borrowers and fences its peer first. A
    /// failed fence retains every root and the process reservation for retry.
    func close(peerFence: () throws -> Void, check: () throws -> Void) throws {
        guard operation.try() else { throw ProbeError("Cannot close an active GLM resident operation") }
        defer { operation.unlock() }
        guard phase != .closed else { return }
        do {
            try peerFence()
            guard borrowHandles.allSatisfy({ $0.value == nil }) else {
                throw ProbeError("GLM resident still has active component/session borrows")
            }
            try hooks.beforeCleanupFence?()
            if ownsProcessLease {
                try MLX.withError { errors in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize()
                    try errors.check(); try check()
                }
            } else { try check() }
            roots.releaseAfterConfirmedFence()
            mtp = nil; vision = nil; stage = nil; loader = nil; inventory = nil
            guard loadedModel == nil, loadedMTP == nil, loadedVision == nil,
                  borrowedComponents.values.allSatisfy({ $0.value == nil }) else {
                throw ProbeError("GLM resident model still has external session/component owners")
            }
            if ownsProcessLease && !requiresProcessExit {
                processLease.release(); ownsProcessLease = false
            }
            borrowHandles.removeAll(); borrowedComponents.removeAll()
            phase = .closed
        } catch { phase = .failed; throw error }
    }

    deinit {
        if ownsProcessLease {
            // An abandoned owner must not free unfenced native roots or reopen
            // process admission. Recovery is explicit close or process exit.
            var retained: [AnyObject] = [roots, processLease]
            if let loader { retained.append(loader) }
            if let stage { retained.append(stage.model) }
            if let mtp { retained.append(mtp) }
            if let vision { retained.append(vision) }
            GLM5NextAbandonedResidents.shared.retain(retained)
        }
    }

    static func inspect(directory: URL, identity: GLM5NextArtifactIdentity,
                                storage: GLM5NextWeightInventory.Storage) throws -> GLM5NextWeightInventory {
        let limits = GLM5NextArtifactLimits()
        guard directory.isFileURL, identity.files.count <= limits.maximumShards + 2,
              identity.files.keys.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("\\")
                  && $0 != "." && $0 != ".." && !$0.utf8.contains(0) }) else {
            throw ProbeError("GLM resident metadata requires bounded local manifest paths")
        }
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw ProbeError("Cannot open GLM metadata directory") }
        defer { Darwin.close(root) }
        func withFile<T>(_ name: String, body: (FileHandle, Int) throws -> T) throws -> T {
            guard let expected = identity.files[name], expected.bytes > 0,
                  qwenStageWireIsSHA256(expected.sha256) else { throw ProbeError("Missing GLM manifest file") }
            let fd = openat(root, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw ProbeError("Cannot open GLM metadata file") }
            defer { Darwin.close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                  before.st_size == expected.bytes else { throw ProbeError("GLM metadata file size/type differs") }
            let result = try body(FileHandle(fileDescriptor: fd, closeOnDealloc: false), expected.bytes)
            var after = stat()
            guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
                throw ProbeError("GLM metadata changed during admission")
            }
            return result
        }
        func read(_ handle: FileHandle, count: Int) throws -> Data {
            guard let data = try handle.read(upToCount: count), data.count == count else {
                throw ProbeError("Truncated GLM metadata")
            }
            return data
        }
        func metadata(_ name: String, limit: Int) throws -> Data {
            try withFile(name) { handle, size in
                guard size <= limit else { throw ProbeError("GLM metadata exceeds its byte bound") }
                let data = try read(handle, count: size)
                guard sha256(data) == identity.files[name]!.sha256 else { throw ProbeError("GLM metadata hash differs") }
                return data
            }
        }
        let config = try metadata("config.json", limit: limits.maximumConfigBytes)
        let index = try metadata("model.safetensors.index.json", limit: limits.maximumIndexBytes)
        let configuration = try JSONDecoder().decode(GLM5NextConfiguration.self, from: config)
        let inventory = try GLM5NextHeaderInventory.validate(configuration: configuration, index: index,
            storage: storage, configurationBytes: config.count) { name in
                try withFile(name) { handle, size in
                    guard size >= 8 else { throw ProbeError("Truncated GLM shard") }
                    let prefix = try read(handle, count: 8)
                    let count = prefix.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
                    guard count > 0, count <= UInt64(limits.maximumHeaderBytes),
                          count <= UInt64(size - 8) else { throw ProbeError("GLM header exceeds its bound") }
                    return .init(data: try read(handle, count: Int(count)), fileBytes: size)
                }
            }
        let names = Set(inventory.entries.values.map { $0.tensor.shard })
            .union(["config.json", "model.safetensors.index.json"])
        guard names == Set(identity.files.keys) else { throw ProbeError("GLM manifest/index file coverage differs") }
        return inventory
    }
}

/// At most the failed process lease's owner in production. Never a serving cache.
private final class GLM5NextAbandonedResidents: @unchecked Sendable {
    static let shared = GLM5NextAbandonedResidents()
    private let lock = NSLock()
    private var objects: [AnyObject] = []
    func retain(_ values: [AnyObject]) {
        lock.lock(); defer { lock.unlock() }
        objects.append(contentsOf: values)
    }
}
