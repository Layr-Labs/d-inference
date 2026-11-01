import Foundation
import MLX
import MLXLLM
import Testing
@testable import DarkbloomClusterRuntime

@Suite("GLM request physical allocation budget", .serialized)
struct GLM5NextRequestStateBudgetTests {
    typealias Budget = GLM5NextRequestStateBudget
    static let environment = String(repeating: "e", count: 64)
    static let scope = Budget.Scope(maximumContextTokens: 256, maximumPromptTokens: 240,
        maximumOutputTokens: 16, maximumChunkTokens: 16)
    static let transport = Budget.TransportTerms(maximumRecordPlaintextBytes: 1 << 20,
        maximumTransportFrameBytes: 2 << 20, maximumControlBytes: 16_384)

    /// Synthetic explicit terms, not production qualification values.
    static func workspace(_ inventory: GLM5NextWeightInventory,
                          scope: Budget.Scope = GLM5NextRequestStateBudgetTests.scope,
                          policy: GLM5NextExecutionPolicy = .reference,
                          nativeBytes: Int = 1 << 20, hostBytes: Int = 1 << 20) throws -> Budget.WorkspaceEvidence {
        .init(kind: .conservative, evidenceSHA256: String(repeating: "a", count: 64),
            configurationSHA256: sha256(try canonicalJSONData(inventory.configuration.textConfig)),
            inventorySHA256: GLM5NextArtifactMetadata.fingerprint(inventory),
            numericalPolicySHA256: try GLM5NextStageContract.policySHA256(policy),
            executionEnvironmentSHA256: environment, layers: 0..<inventory.configuration.textConfig.hiddenLayers,
            scope: scope, nativeBytes: nativeBytes, hostBytes: hostBytes)
    }

    static func quote(_ inventory: GLM5NextWeightInventory, layers: Range<Int> = 0..<4,
                      rank: Int = 0, scope: Budget.Scope = GLM5NextRequestStateBudgetTests.scope,
                      bound: (Int) throws -> Int = { $0 }) throws -> Budget {
        try Budget.estimate(inventory: inventory, layers: layers, rank: rank, scope: scope,
            executionPolicy: .reference, executionEnvironmentSHA256: environment,
            workspace: workspace(inventory, scope: scope), transport: transport,
            maximumBufferBytes: Int.max, allocationBound: bound, hostAllocationBound: { $0 })
    }

    @Test func physicalHistoryRollbackAndChunkLogitsHaveIndependentCharges() throws {
        let inventory = try GLM5NextMetadataTestFixture(layers: 8).inventory
        let first = try Self.quote(inventory)
        let last = try Self.quote(inventory, layers: 4..<8, rank: 1)
        #expect(first.dsaCapacityTokens == 512)
        // One DSA layer: 2 FP32 latent columns, two sets of 2 FP32
        // index columns and validity: 25 bytes/token. Three capacity buffers
        // plus a 16-token append, all independently bounded.
        #expect(first.dsaTransactionBytes == (3 * 512 + 16) * 25)
        // Three KDA layers: six compact pairs (including the native
        // contiguous tail allowance), plus two full pending/cast histories.
        #expect(first.kdaTransactionBytes == 3 * (6 * (96 + 16_384 + 16 + 16_384) + 2 * 480))
        #expect(first.boundaryBytes == 2 * 16 * 4 * 4 * 4)
        #expect(first.logitsBytes == 0 && last.logitsBytes == 2 * 16 * 32 * 4)
        #expect(last.nativeBytes - first.nativeBytes == last.logitsBytes)
        #expect(first.hostBytes > first.workspaceHostBytes)
        #expect(first.reservedBytes == first.nativeBytes + first.hostBytes)
        let rounded = try Self.quote(inventory, bound: { ($0 + 255) / 256 * 256 })
        #expect(rounded.dsaTransactionBytes > first.dsaTransactionBytes)
        let expectedRounded = 3 * (6 * (16_640 + 16_640) + 2 * 512)
        #expect(rounded.kdaTransactionBytes == expectedRounded)
        #expect(rounded.kdaTransactionBytes > first.kdaTransactionBytes)
    }

    @Test func absentMismatchedAndInsufficientTermsRefuse() throws {
        let inventory = try GLM5NextMetadataTestFixture(layers: 8).inventory
        let evidence = try Self.workspace(inventory)
        func attempt(workspace: Budget.WorkspaceEvidence?, transport: Budget.TransportTerms?,
                     environment: String = Self.environment, maximum: Int = Int.max,
                     bound: (Int) throws -> Int = { $0 }) throws {
            _ = try Budget.estimate(inventory: inventory, layers: 0..<4, rank: 0, scope: Self.scope,
                executionPolicy: .reference, executionEnvironmentSHA256: environment,
                workspace: workspace, transport: transport, maximumBufferBytes: maximum,
                allocationBound: bound, hostAllocationBound: { $0 })
        }
        #expect(throws: ProbeError.self) { try attempt(workspace: nil, transport: Self.transport) }
        #expect(throws: ProbeError.self) { try attempt(workspace: evidence, transport: nil) }
        #expect(throws: ProbeError.self) {
            try attempt(workspace: evidence, transport: Self.transport, environment: String(repeating: "f", count: 64))
        }
        #expect(throws: ProbeError.self) { try attempt(workspace: evidence, transport: Self.transport, maximum: 32) }
        #expect(throws: ProbeError.self) { try attempt(workspace: evidence, transport: Self.transport, bound: { $0 - 1 }) }
        #expect(throws: ProbeError.self) { try attempt(workspace: evidence, transport: Self.transport, bound: { _ in Int.max }) }
        #expect(throws: ProbeError.self) {
            try attempt(workspace: evidence, transport: .init(maximumRecordPlaintextBytes: 1024,
                maximumTransportFrameBytes: 2048, maximumControlBytes: 1024))
        }
        let smaller = Budget.Scope(maximumContextTokens: 32, maximumPromptTokens: 24,
            maximumOutputTokens: 8, maximumChunkTokens: 8)
        #expect(throws: ProbeError.self) {
            try attempt(workspace: Self.workspace(inventory, scope: smaller), transport: Self.transport)
        }
        var fused = GLM5NextExecutionPolicy.reference
        fused.projections = .fusedInputs
        #expect(throws: ProbeError.self) {
            try attempt(workspace: Self.workspace(inventory, policy: fused), transport: Self.transport)
        }
        #expect(throws: ProbeError.self) {
            try attempt(workspace: Self.workspace(inventory, nativeBytes: 0), transport: Self.transport)
        }
        #expect(throws: ProbeError.self) {
            try attempt(workspace: Self.workspace(inventory, hostBytes: 0), transport: Self.transport)
        }
        let foreign = try GLM5NextMetadataTestFixture(layers: 4).inventory
        #expect(throws: ProbeError.self) {
            try attempt(workspace: Self.workspace(foreign), transport: Self.transport)
        }
        var mtp = Self.scope
        mtp.includesMTP = true
        #expect(throws: ProbeError.self) { try Self.quote(inventory, scope: mtp) }
        var batch = Self.scope
        batch.batchSize = 2
        #expect(throws: ProbeError.self) { try Self.quote(inventory, scope: batch) }
        #expect(throws: ProbeError.self) { try Budget.product([Int.max, 2]) }
        #expect(throws: ProbeError.self) { try Budget.sum([Int.max, 1]) }
    }

    @Test func imageScopeAddsItsOwnedBuffersAndRequiresMatchingWorkspace() throws {
        let inventory = try GLM5NextMetadataTestFixture(layers: 8).inventory
        var imageScope = Self.scope
        imageScope.includesVision = true
        for rank in 0...1 {
            let layers = rank == 0 ? 0..<4 : 4..<8
            let text = try Self.quote(inventory, layers: layers, rank: rank)
            let image = try Self.quote(inventory, layers: layers, rank: rank, scope: imageScope)
            let media = try GLM5NextImageBudget.bytes(configuration: inventory.configuration,
                rank: rank, chunk: imageScope.maximumChunkTokens, native: { $0 }, host: { $0 })
            #expect(rank == 0 ? media.native > 0 : media.native == 0)
            #expect(media.host > 0)
            #expect(image.nativeBytes == text.nativeBytes + media.native)
            #expect(image.hostBytes == text.hostBytes + media.host)
            #expect(image.reservedBytes == text.reservedBytes + media.native + media.host)
            #expect(image.boundaryBytes == text.boundaryBytes && image.logitsBytes == text.logitsBytes)
            #expect(throws: ProbeError.self) {
                _ = try Budget.estimate(inventory: inventory, layers: layers, rank: rank, scope: imageScope,
                    executionPolicy: .reference, executionEnvironmentSHA256: Self.environment,
                    workspace: Self.workspace(inventory), transport: Self.transport,
                    maximumBufferBytes: Int.max, allocationBound: { $0 }, hostAllocationBound: { $0 })
            }
        }
    }

    /// Actual evaluated buffer metadata, not allocator-delta inference. This
    /// checks exposed committed/copied cache backing, not hidden workspace or
    /// proof that native storage was released. The full peak still needs evidence.
    @Test func tinyNativeCacheBackingAndCopiedRewindFitNamedStateBounds() throws {
        defer {
            do {
                try MLX.withError { error in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
                }
            } catch { Issue.record(error, "GLM budget fixture cleanup fence failed") }
        }
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let loader = try artifact.loader()
        let c = loader.configuration.textConfig
        let stage = try loader.loadTextStage(plan: .init(configuration: c, layers: 0..<4))
        let cache = stage.newCache()
        let budget = try Self.quote(loader.inventory, bound: Memory.allocationFootprintUpperBound)
        func step(_ tokens: [Int32]) throws {
            try stage.prepareForward(tokens: MLXArray(tokens, [1, tokens.count]), cache: cache)
                .commit { arrays in
                    try MLX.withError { error in
                        eval(arrays); Stream.gpu.synchronize(); Stream.cpu.synchronize()
                        try error.check()
                    }
                }
        }
        try step([4, 5])
        let before = cache.copy()
        try step([6]) // DSA grows from 2 columns to its 256-column backing.
        let copied = cache.copy()
        var dsaBytes = 0, kdaBytes = 0, sawSpareCapacity = false
        for retained in [before, cache, copied] {
            for layer in retained.layers {
                // state returns fresh logical slices of DSA backing; evaluate
                // those views explicitly before asking public buffer metadata.
                let arrays = layer.state
                try MLX.withError { error in
                    eval(arrays); Stream.gpu.synchronize(); Stream.cpu.synchronize()
                    try error.check()
                }
                for array in arrays {
                    let info = try #require(try array.evaluatedBufferInfo())
                    if layer is GLM5NextDSACache {
                        dsaBytes += info.allocatedBytes
                        if retained.offset == 3 && info.allocatedBytes > array.nbytes { sawSpareCapacity = true }
                    } else {
                        kdaBytes += info.allocatedBytes
                    }
                }
            }
        }
        #expect(sawSpareCapacity)
        #expect(dsaBytes <= budget.dsaTransactionBytes)
        #expect(kdaBytes <= budget.kdaTransactionBytes)
        try copied.truncate(to: 2)
        #expect(copied.offset == 2 && cache.offset == 3 && before.offset == 2)
        withExtendedLifetime([before, cache, copied]) {}
    }
}
