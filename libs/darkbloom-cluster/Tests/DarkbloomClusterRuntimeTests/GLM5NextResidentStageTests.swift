import Cmlx
import Darwin
import Foundation
import MLX
import MLXLLM
import Testing
@testable import DarkbloomClusterRuntime

/// These load tiny real files through the SDK, the live host gate and real
/// evaluation/fences. Run in the parent's exclusive native lane.
@Suite("GLM verified resident ownership", .serialized)
struct GLM5NextResidentStageTests {
    private enum Failure: Error { case injected }

    private func identity(_ artifact: GLM5NextStageSessionTests.Artifact) throws -> GLM5NextArtifactIdentity {
        let names = ["config.json", "model.safetensors.index.json"] + artifact.metadata.shards.keys.sorted()
        let files = try Dictionary(uniqueKeysWithValues: names.map { name in
            let data = try Data(contentsOf: artifact.url(name))
            return (name, GLM5NextArtifactIdentity.File(bytes: data.count, sha256: sha256(data)))
        })
        return .init(repository: "synthetic/glm-stage-session", revision: String(repeating: "a", count: 40),
            files: files)
    }

    private func resident(_ artifact: GLM5NextStageSessionTests.Artifact,
                          rank: Int = 1, mtp: Bool = true, capacity: Int = 8 << 30,
                          hooks: GLM5NextResidentLoadHooks = .init(),
                          lease: QwenResidentProcessLease) throws -> GLM5NextResidentStage {
        try .init(directory: artifact.directory, expectedIdentity: identity(artifact),
            artifactAggregateSHA256: String(repeating: "b", count: 64), storage: .float32,
            stageIndex: rank, cut: 3, includeMTP: mtp, executionPolicy: .reference,
            capacityLimitBytes: capacity, executionStateReserveBytes: 1 << 20,
            workspaceReserveBytes: 1 << 20, hooks: hooks, processLease: lease)
    }

    @Test func capacityRefusalPrecedesFullArtifactVerificationAndTensorAllocation() throws {
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let lease = QwenResidentProcessLease()
        var verification = 0, reads = 0, evaluations = 0
        var hooks = GLM5NextResidentLoadHooks()
        hooks.beforeVerification = { verification += 1 }
        hooks.beforeTensorRead = { _, _ in reads += 1 }
        hooks.beforeEvaluation = { _ in evaluations += 1 }
        #expect(throws: ProbeError.self) {
            try resident(artifact, capacity: 1, hooks: hooks, lease: lease)
        }
        #expect(verification == 0 && reads == 0 && evaluations == 0)
        try lease.acquire()
        lease.release()
    }

    @Test func nonregularMetadataIsRefusedWithoutWaitingForPayload() throws {
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let expected = try identity(artifact)
        let config = artifact.url("config.json")
        try FileManager.default.removeItem(at: config)
        let created = mkfifo(config.path, 0o600)
        try #require(created == 0)
        #expect(throws: ProbeError.self) {
            try GLM5NextResidentStage(directory: artifact.directory, expectedIdentity: expected,
                artifactAggregateSHA256: String(repeating: "b", count: 64), storage: .float32,
                stageIndex: 1, cut: 3, includeMTP: true, executionPolicy: .reference,
                capacityLimitBytes: 8 << 30, executionStateReserveBytes: 1 << 20,
                workspaceReserveBytes: 1 << 20, processLease: QwenResidentProcessLease())
        }
    }

    @Test func selectedReadsAndMTPIdentityMatchReceipts() throws {
        let artifact = try GLM5NextStageSessionTests.Artifact()
        for (rank, mtp) in [(0, false), (1, false), (1, true)] {
            let lease = QwenResidentProcessLease()
            var reads: [String: Int] = [:]
            var hooks = GLM5NextResidentLoadHooks()
            hooks.beforeTensorRead = { name, bytes in
                #expect(reads.updateValue(bytes, forKey: name) == nil)
            }
            let owner = try resident(artifact, rank: rank, mtp: mtp, hooks: hooks, lease: lease)
            defer { try? owner.close(peerFence: {}, check: {}) }
            try owner.load(check: {})
            let receipt = try #require(owner.receipt)
            #expect(owner.phase == .loaded)
            #expect(receipt.selectedPayloadBytes == owner.resources.summary.selectedStoredBytes)
            #expect(receipt.selectedPayloadTensorCount == reads.count)
            #expect(Set(reads.keys) == Set(owner.resources.selected.keys))
            #expect(reads.keys.allSatisfy { artifact.metadata.inventory.entries[$0]!.part != .vision })
            #expect(receipt.resources.deferredVisionStoredBytes == artifact.metadata.inventory.bytes(in: .vision))
            #expect(receipt.admission.admitted)
            #expect(receipt.reservedBytes == receipt.resources.initialLoadPeakBytes
                + receipt.executionStateReserveBytes + receipt.workspaceReserveBytes)
            #expect(receipt.reservedBytes <= receipt.capacityLimitBytes)
            weak var model: GLM5NextTextStage?
            weak var head: GLM5NextMTP?
            do {
                let borrowed = try owner.borrowComponent { stage, candidate in
                    model = stage.model; head = candidate
                    #expect(stage.stageIndex == rank)
                    #expect((candidate != nil) == (rank == 1 && mtp))
                    if let candidate {
                        #expect(candidate.targetIdentity == ObjectIdentifier(stage.model))
                        #expect(stage.model.embedding != nil)
                    }
                    #expect(throws: ProbeError.self) { try owner.close(peerFence: {}, check: {}) }
                    return stage.model
                }
                #expect(borrowed.value === model)
            }
            #expect(throws: ProbeError.self) { try owner.load(check: {}) }
            #expect(throws: ProbeError.self) { try lease.acquire() }
            try owner.close(peerFence: {}, check: {})
            #expect(model == nil && head == nil)
            #expect(owner.phase == .closed && owner.retainedOwnerCount == 0 && owner.retainedArrayCount == 0)
            try owner.close(peerFence: { throw Failure.injected }, check: {})
            #expect(owner.requiresProcessExit)
            #expect(throws: ProbeError.self) { try lease.acquire() }
        }
    }

    @Test func unborrowedStagesReleaseAdmissionForRepeatedLifetimes() throws {
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let lease = QwenResidentProcessLease()
        for _ in 0..<2 {
            let owner = try resident(artifact, lease: lease)
            defer {
                do { try owner.close(peerFence: {}, check: {}) }
                catch { Issue.record("Resident cleanup failed: \(error)") }
            }
            try owner.load(check: {})
            try owner.close(peerFence: {}, check: {})
            #expect(owner.phase == .closed && !owner.requiresProcessExit)
            #expect(owner.retainedArrayCount == 0 && owner.retainedOwnerCount == 0)
            try lease.acquire()
            lease.release()
        }
    }

    @Test func partialLoadAndFailedFenceRetainRootsAndBlockReplacementUntilCleanup() throws {
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let lease = QwenResidentProcessLease()
        var reads = 0, failCleanup = true
        var hooks = GLM5NextResidentLoadHooks()
        hooks.beforeTensorRead = { _, _ in
            reads += 1
            if reads == 3 { throw Failure.injected }
        }
        hooks.beforeCleanupFence = { if failCleanup { throw Failure.injected } }
        let owner = try resident(artifact, hooks: hooks, lease: lease)
        defer { failCleanup = false; try? owner.close(peerFence: {}, check: {}) }
        #expect(throws: Failure.self) { try owner.load(check: {}) }
        #expect(owner.phase == .failed && owner.receipt == nil)
        let arrays = owner.retainedArrayCount
        #expect(arrays > 0)
        let replacement = try resident(artifact, lease: lease)
        #expect(throws: ProbeError.self) { try replacement.load(check: {}) }
        #expect(replacement.phase == .prepared)
        #expect(throws: Failure.self) { try owner.close(peerFence: {}, check: {}) }
        #expect(owner.retainedArrayCount == arrays && owner.phase == .failed)
        #expect(throws: ProbeError.self) { try lease.acquire() }
        failCleanup = false
        try owner.close(peerFence: {}, check: {})
        #expect(owner.phase == .closed && owner.retainedArrayCount == 0)
        try replacement.load(check: {})
        try replacement.close(peerFence: {}, check: {})
        #expect(replacement.phase == .closed)
    }

    @Test func failedPeerFenceAndBorrowedModelKeepAdmissionClosed() throws {
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let lease = QwenResidentProcessLease()
        let owner = try resident(artifact, lease: lease)
        defer { try? owner.close(peerFence: {}, check: {}) }
        try owner.load(check: {})
        let retained = owner.retainedOwnerCount
        #expect(throws: Failure.self) {
            try owner.close(peerFence: { throw Failure.injected }, check: {})
        }
        #expect(owner.retainedOwnerCount == retained && owner.phase == .failed)
        #expect(throws: ProbeError.self) { try lease.acquire() }
        try owner.close(peerFence: {}, check: {})

        let next = try resident(artifact, lease: lease)
        try next.load(check: {})
        var borrowed: GLM5NextResidentStage.Borrow<GLM5NextTextStage>? =
            try next.borrowComponent { stage, _ in stage.model }
        #expect(throws: ProbeError.self) { try next.close(peerFence: {}, check: {}) }
        let borrowedRemains = borrowed != nil
        #expect(borrowedRemains && next.phase == .failed)
        #expect(throws: ProbeError.self) { try lease.acquire() }
        borrowed = nil
        try next.close(peerFence: {}, check: {})
        #expect(next.phase == .closed && next.requiresProcessExit)
        #expect(throws: ProbeError.self) { try lease.acquire() }
    }

    @Test(arguments: [false, true])
    func componentOnlyBorrowKeepsAdmissionClosed(arrayOnly: Bool) throws {
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let lease = QwenResidentProcessLease()
        let owner = try resident(artifact, lease: lease)
        var borrowed: GLM5NextResidentStage.Borrow<AnyObject>?
        var escaped: AnyObject?
        defer {
            escaped = nil; borrowed = nil
            do { try owner.close(peerFence: {}, check: {}) }
            catch { Issue.record("Resident cleanup failed: \(error)") }
        }
        try owner.load(check: {})
        weak var model: GLM5NextTextStage?
        borrowed = try owner.borrowComponent { stage, _ -> AnyObject in
            model = stage.model
            if arrayOnly { return stage.model.layers[0].parameters().flattened()[0].1 }
            return stage.model.layers[0]
        }
        let retained = owner.retainedOwnerCount
        withExtendedLifetime(borrowed) {
            #expect(throws: ProbeError.self) { try owner.close(peerFence: {}, check: {}) }
        }
        #expect(owner.retainedOwnerCount == retained && model != nil)
        #expect(throws: ProbeError.self) { try lease.acquire() }

        // Even dropping the handle cannot refund admission while its selected
        // object survives. No complete model is retained by this borrower.
        escaped = borrowed?.value
        borrowed = nil
        withExtendedLifetime(escaped) {
            #expect(throws: ProbeError.self) { try owner.close(peerFence: {}, check: {}) }
            #expect(model == nil && owner.phase == .failed)
            #expect(throws: ProbeError.self) { try lease.acquire() }
        }
        escaped = nil
        try owner.close(peerFence: {}, check: {})
        #expect(owner.phase == .closed && owner.requiresProcessExit)
        #expect(throws: ProbeError.self) { try lease.acquire() }
    }

    @Test(arguments: [false, true])
    func escapedParameterViewRequiresProcessExit(selectionThrows: Bool) throws {
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let lease = QwenResidentProcessLease()
        let owner = try resident(artifact, lease: lease)
        var view: MLXArray?
        weak var original: MLXArray?
        defer {
            view = nil
            do { try owner.close(peerFence: {}, check: {}) }
            catch { Issue.record("Resident cleanup failed: \(error)") }
        }
        try owner.load(check: {})
        do {
            let borrowed = try owner.borrowComponent { stage, _ -> MLXArray in
                let weight = try #require(stage.model.head?.weight)
                original = weight
                if selectionThrows {
                    view = weight.reshaped(-1)
                    eval(view!)
                    throw Failure.injected
                }
                return weight
            }
            view = borrowed.value.reshaped(-1)
            eval(view!)
        } catch Failure.injected {
            #expect(selectionThrows)
        }
        try owner.close(peerFence: {}, check: {})
        #expect(original == nil)
        #expect(owner.phase == .closed && owner.requiresProcessExit)
        #expect(owner.retainedArrayCount == 0 && owner.retainedOwnerCount == 0)
        // The original Swift wrapper is gone, but its evaluated native view
        // remains usable. No allocator counter or weak wrapper proves release.
        do {
            let survivor = try #require(view)
            var available = false
            #expect(_mlx_array_is_available(&available, survivor.ctx) == 0)
            #expect(available && survivor.size > 0)
            #expect(throws: ProbeError.self) { try lease.acquire() }
        }
        view = nil
        #expect(throws: ProbeError.self) { try lease.acquire() }
        try owner.close(peerFence: {}, check: {})
        #expect(throws: ProbeError.self) { try lease.acquire() }
    }

    @Test(arguments: [false, true])
    func evaluationHookEscapedViewKeepsReplacementAdmissionClosed(hookThrows: Bool) throws {
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let lease = QwenResidentProcessLease()
        var view: MLXArray?
        var exposures = 0
        var hooks = GLM5NextResidentLoadHooks()
        hooks.beforeEvaluation = { arrays in
            guard view == nil, let parameter = arrays.first else { return }
            let escaped = parameter.reshaped(-1)
            try MLX.withError { errors in
                eval(escaped)
                try errors.check()
            }
            view = escaped
            exposures += 1
            if hookThrows { throw Failure.injected }
        }
        let owner = try resident(artifact, hooks: hooks, lease: lease)
        defer {
            view = nil
            do { try owner.close(peerFence: {}, check: {}) }
            catch { Issue.record("Resident cleanup failed: \(error)") }
        }
        if hookThrows {
            #expect(throws: Failure.self) { try owner.load(check: {}) }
            #expect(owner.phase == .failed && owner.receipt == nil)
        } else {
            try owner.load(check: {})
            #expect(owner.phase == .loaded && owner.receipt != nil)
        }
        try #require(exposures == 1 && view != nil)
        var peerFences = 0
        try owner.close(peerFence: { peerFences += 1 }, check: {})
        #expect(peerFences == 1 && owner.phase == .closed)
        #expect(owner.retainedArrayCount == 0 && owner.retainedOwnerCount == 0)
        #expect(owner.requiresProcessExit)
        // The evaluated view survives root retirement independently of the
        // original Swift wrapper. Availability is not evidence of release.
        do {
            let survivor = try #require(view)
            var available = false
            #expect(_mlx_array_is_available(&available, survivor.ctx) == 0)
            #expect(available && survivor.size > 0)
            #expect(throws: ProbeError.self) {
                try lease.acquire()
                // Avoid masking subsequent failures if the broken owner reopens it.
                lease.release()
            }
        }
        view = nil
        try owner.close(peerFence: { throw Failure.injected }, check: {})
        #expect(throws: ProbeError.self) {
            try lease.acquire()
            lease.release()
        }
    }

    @Test(arguments: [false, true])
    func lateCancellationRefusesEvaluationAndRetainsAdmission(fromEvaluationHook: Bool) throws {
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let lease = QwenResidentProcessLease()
        var cancelled = false, reads = 0, evaluations = 0
        var unevaluatedBank: MLXArray?
        var hooks = GLM5NextResidentLoadHooks()
        hooks.beforeTensorRead = { _, _ in
            reads += 1
            if !fromEvaluationHook { cancelled = true }
        }
        hooks.beforeEvaluation = { arrays in
            evaluations += 1
            if fromEvaluationHook {
                for array in arrays {
                    var available = true
                    try #require(_mlx_array_is_available(&available, array.ctx) == 0)
                    if !available {
                        unevaluatedBank = array
                        cancelled = true
                        break
                    }
                }
            }
        }
        let owner = try resident(artifact, hooks: hooks, lease: lease)
        defer {
            unevaluatedBank = nil
            do { try owner.close(peerFence: {}, check: {}) }
            catch { Issue.record("Resident cleanup failed: \(error)") }
        }
        #expect(throws: Failure.self) {
            try owner.load(check: { if cancelled { throw Failure.injected } })
        }
        if fromEvaluationHook {
            let bank = try #require(unevaluatedBank)
            var available = true
            #expect(_mlx_array_is_available(&available, bank.ctx) == 0)
            #expect(!available && cancelled && reads > 0 && evaluations > 0)
        } else {
            #expect(reads == 1 && evaluations == 0)
        }
        #expect(owner.phase == .failed && owner.receipt == nil)
        #expect(owner.retainedArrayCount > 0)
        #expect(throws: ProbeError.self) { try lease.acquire() }
        unevaluatedBank = nil
        try owner.close(peerFence: {}, check: {})
        #expect(owner.requiresProcessExit == fromEvaluationHook)
        if fromEvaluationHook {
            #expect(throws: ProbeError.self) { try lease.acquire() }
        } else {
            try lease.acquire()
            lease.release()
        }
    }

    @Test func metadataReplacementCannotChangeAnAdmittedSource() throws {
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let lease = QwenResidentProcessLease()
        var reads = 0
        var hooks = GLM5NextResidentLoadHooks()
        hooks.beforeTensorRead = { _, _ in reads += 1 }
        let owner = try resident(artifact, hooks: hooks, lease: lease)
        defer { try? owner.close(peerFence: {}, check: {}) }
        var config = try Data(contentsOf: artifact.url("config.json"))
        config[config.count - 1] = 32
        try config.write(to: artifact.url("config.json"))
        #expect(throws: GLM5NextArtifactError.self) { try owner.load(check: {}) }
        #expect(reads == 0 && owner.phase == .failed && owner.receipt == nil)
        #expect(throws: ProbeError.self) { try lease.acquire() }
        try owner.close(peerFence: {}, check: {})
    }
}
