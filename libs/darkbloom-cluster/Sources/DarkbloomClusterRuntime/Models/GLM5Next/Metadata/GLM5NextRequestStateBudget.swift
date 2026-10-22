import DarkbloomClusterSecurity
import Foundation
import MLXLLM

/// Named physical allocations for the current serial, cold, two-stage driver.
/// This is a quotation, not admission or a measured whole-process peak. The
/// owner must authenticate workspace evidence and recheck live memory/deadlines.
struct GLM5NextRequestStateBudget: Equatable {
    struct Scope: Codable, Equatable {
        let maximumContextTokens: Int
        let maximumPromptTokens: Int
        let maximumOutputTokens: Int
        let maximumChunkTokens: Int
        var batchSize = 1
        var includesMTP = false
        var includesVision = false

        func validate(configuration c: GLM5NextTextConfiguration) throws {
            guard batchSize == 1, !includesMTP,
                  maximumContextTokens > 0, maximumContextTokens <= c.maxPositionEmbeddings,
                  maximumPromptTokens > 0, maximumOutputTokens > 0,
                  maximumChunkTokens > 0, maximumChunkTokens <= maximumPromptTokens,
                  // The protocol's limits: each leaves room for one token of the
                  // other; every request's own prompt plus output is held to the
                  // context. The budget is a function of context and chunk only.
                  maximumPromptTokens < maximumContextTokens,
                  maximumOutputTokens < maximumContextTokens else {
                throw ProbeError("GLM budget requires a bounded single-request text pipeline scope")
            }
        }
        func covers(_ other: Self) -> Bool {
            batchSize == other.batchSize && includesMTP == other.includesMTP
                && includesVision == other.includesVision
                && maximumContextTokens >= other.maximumContextTokens
                && maximumPromptTokens >= other.maximumPromptTokens
                && maximumOutputTokens >= other.maximumOutputTokens
                && maximumChunkTokens >= other.maximumChunkTokens
        }
    }

    /// Additional graph/kernel/selection workspace and host allocator/CryptoKit
    /// scratch, beyond the named buffers below. No default or inferred floor.
    /// Measured evidence must qualify the whole stated request envelope, not
    /// just one observed peak. It is accepted only for the exact layer/scope
    /// envelope; only conservative evidence can cover a subset.
    /// Hashes bind evidence to the inventory, policy and caller's qualified
    /// binary/backend/device environment. A hash is not authentication by itself.
    struct WorkspaceEvidence: Codable, Equatable {
        enum Kind: String, Codable, Equatable { case measured, conservative, experimentalAllowance }
        let kind: Kind
        let evidenceSHA256: String
        let configurationSHA256: String
        let inventorySHA256: String
        let numericalPolicySHA256: String
        let executionEnvironmentSHA256: String
        let layers: Range<Int>
        let scope: Scope
        let nativeBytes: Int
        let hostBytes: Int
    }

    /// How a DSA history's token columns are bounded.
    enum HistoryBound: Equatable {
        /// The cache's own doubling (`GLM5NextDSACache`, no capacity limit):
        /// up to `max(256, 2 * context)` columns, charged three times
        /// (committed, tentative and the growth copy).
        case geometric
        /// A cache whose growth stops at this many columns
        /// (`GLM5NextDSACache.capacityLimit`, at least the context): charged
        /// twice, the history and the one fresh buffer an append writes before
        /// the history it replaces is released.
        case reserved(tokens: Int)

        func columns(contextTokens: Int) throws -> (capacity: Int, copies: Int) {
            switch self {
            case .geometric: return (max(256, try GLM5NextRequestStateBudget.product([2, contextTokens])), 3)
            case .reserved(let tokens):
                guard tokens >= contextTokens else { throw ProbeError("GLM history bound is below its context") }
                return (tokens, 2)
            }
        }
    }

    /// Must match the owner's negotiated authenticated transport limits.
    struct TransportTerms: Codable, Equatable {
        let maximumRecordPlaintextBytes: Int
        let maximumTransportFrameBytes: Int
        /// Includes request/control/ACK framing, not just residual payloads.
        let maximumControlBytes: Int
    }

    let rank: Int
    let layers: Range<Int>
    let scope: Scope
    let dsaCapacityTokens: Int
    let dsaTransactionBytes: Int
    let kdaTransactionBytes: Int
    let boundaryBytes: Int
    let logitsBytes: Int
    let inputBytes: Int
    let tokenHostBytes: Int
    let transportNativeBytes: Int
    let transportHostBytes: Int
    let workspaceNativeBytes: Int
    let workspaceHostBytes: Int
    let nativeBytes: Int
    let hostBytes: Int
    let reservedBytes: Int
    let workspaceEvidenceSHA256: String

    /// What `estimate` checks workspace evidence against: the digests of an
    /// inventory, its text configuration and an execution policy. The
    /// inventory's hashes every stored tensor's name, type and shape (the
    /// registered GLM artifact's 114,160 tensors: about 60-120 ms), so a
    /// caller that estimates one immutable inventory again and again (every
    /// request's charge, `GLM5NextTensorParallelRequestCharge`) computes them
    /// once and passes them; the checks are the same.
    struct EvidenceDigests: Equatable {
        let configurationSHA256: String
        let inventorySHA256: String
        let numericalPolicySHA256: String

        init(inventory: GLM5NextWeightInventory, executionPolicy: GLM5NextExecutionPolicy) throws {
            configurationSHA256 = sha256(try canonicalJSONData(inventory.configuration.textConfig))
            inventorySHA256 = GLM5NextArtifactMetadata.fingerprint(inventory)
            numericalPolicySHA256 = try GLM5NextStageContract.policySHA256(executionPolicy)
        }
    }

    /// `digests`: those of exactly this `inventory` and `executionPolicy`
    /// (`EvidenceDigests`); nil computes them here.
    static func estimate(inventory: GLM5NextWeightInventory, layers: Range<Int>, rank: Int,
                         scope: Scope, executionPolicy: GLM5NextExecutionPolicy,
                         executionEnvironmentSHA256: String,
                         workspace: WorkspaceEvidence?, transport: TransportTerms?,
                         maximumBufferBytes: Int,
                         allocationBound: (Int) throws -> Int,
                         hostAllocationBound: (Int) throws -> Int,
                         history: HistoryBound = .geometric,
                         digests: EvidenceDigests? = nil) throws -> Self {
        let c = inventory.configuration.textConfig
        try scope.validate(configuration: c)
        guard (0...1).contains(rank), !layers.isEmpty, layers.lowerBound >= 0,
              layers.upperBound <= c.hiddenLayers, c.hcMult == 4,
              ["float32", "bfloat16"].contains(c.dtype), maximumBufferBytes > 0,
              let workspace, let transport,
              workspace.layers.lowerBound >= 0, workspace.layers.upperBound <= c.hiddenLayers,
              workspace.layers.lowerBound <= layers.lowerBound, workspace.layers.upperBound >= layers.upperBound,
              workspace.scope.covers(scope),
              workspace.kind == .conservative || (workspace.layers == layers && workspace.scope == scope),
              workspace.nativeBytes > 0, workspace.hostBytes > 0,
              qwenStageWireIsSHA256(workspace.evidenceSHA256),
              qwenStageWireIsSHA256(executionEnvironmentSHA256),
              workspace.executionEnvironmentSHA256 == executionEnvironmentSHA256,
              workspace.configurationSHA256 == (try digests?.configurationSHA256 ?? sha256(canonicalJSONData(c))),
              workspace.inventorySHA256 == (digests?.inventorySHA256 ?? GLM5NextArtifactMetadata.fingerprint(inventory)),
              workspace.numericalPolicySHA256
                == (try digests?.numericalPolicySHA256 ?? GLM5NextStageContract.policySHA256(executionPolicy)) else {
            throw ProbeError("GLM request budget lacks matching workspace/environment evidence or geometry")
        }
        try workspace.scope.validate(configuration: c)
        func native(_ bytes: Int, copies: Int = 1) throws -> Int {
            let rounded = try allocationBound(bytes)
            guard bytes > 0, rounded >= bytes, rounded <= maximumBufferBytes else {
                throw ProbeError("GLM request allocation exceeds its native buffer bound")
            }
            return try product([rounded, copies])
        }
        func host(_ bytes: Int, copies: Int = 1) throws -> Int {
            let rounded = try hostAllocationBound(bytes)
            guard bytes > 0, rounded >= bytes else { throw ProbeError("GLM host allocation bound is invalid") }
            return try product([rounded, copies])
        }
        let chunk = scope.maximumChunkTokens
        // GLM5NextDSACache starts at the first append length, then grows to
        // max(end, 2*capacity, 256). Without truncation, capacity <= max(256,2*N).
        // Charge committed + tentative + growth padding, plus new input columns
        // (`HistoryBound`: a capacity-limited cache is charged at its limit).
        // All three floating histories use <= FP32; validity is one byte.
        let (capacity, copies) = try history.columns(contextTokens: scope.maximumContextTokens)
        let dsaLayers = layers.filter { c.layerTypes[$0] == .deepseekSparseAttention }.count
        var dsa = 0
        if dsaLayers > 0 {
            let widths = [try product([c.kvLoraRank, 4]),
                          try product([c.indexHeadDim, 4]),
                          try product([c.indexHeadDim, 4]), 1]
            let one = try sum(widths.map { width in
                try sum([native(product([capacity, width]), copies: copies),
                         native(product([chunk, width]))])
            })
            dsa = try product([one, dsaLayers])
        }
        let kdaLayers = layers.count - dsaLayers
        var kda = 0
        if kdaLayers > 0 {
            let one = try linearTransactionBytes(configuration: c.linearAttention, chunk: chunk,
                native: { bytes, copies in try native(bytes, copies: copies) })
            kda = try product([one, kdaLayers])
        }
        let buffers = try transferAndInputBytes(configuration: c, rank: rank, scope: scope, transport: transport,
            nativeBound: { try native($0, copies: $1) }, hostBound: { try host($0, copies: $1) })
        let boundary = buffers.boundary, logits = buffers.logits, wireNative = buffers.wireNative
        let input = buffers.input, tokenHost = buffers.tokenHost, wireHost = buffers.wireHost
        let media = scope.includesVision ? try GLM5NextImageBudget.bytes(configuration: inventory.configuration,
            rank: rank, chunk: chunk, native: { try native($0) }, host: { try host($0) }) : (native: 0, host: 0)
        let nativeBytes = try sum([media.native, dsa, kda, boundary, logits, input, wireNative, workspace.nativeBytes])
        let hostBytes = try sum([media.host, wireHost, tokenHost, workspace.hostBytes])
        return .init(rank: rank, layers: layers, scope: scope, dsaCapacityTokens: capacity,
            dsaTransactionBytes: dsa, kdaTransactionBytes: kda, boundaryBytes: boundary,
            logitsBytes: logits, inputBytes: input, tokenHostBytes: tokenHost,
            transportNativeBytes: wireNative, transportHostBytes: wireHost,
            workspaceNativeBytes: workspace.nativeBytes, workspaceHostBytes: workspace.hostBytes,
            nativeBytes: nativeBytes, hostBytes: hostBytes, reservedBytes: try sum([nativeBytes, hostBytes]),
            workspaceEvidenceSHA256: workspace.evidenceSHA256)
    }

    /// Shared named buffers for native admission and preliminary placement.
    /// Bounding metadata does not allocate a tensor or initialize a device.
    static func transferAndInputBytes(configuration c: GLM5NextTextConfiguration, rank: Int,
                                      scope: Scope, transport: TransportTerms,
                                      nativeBound: (Int, Int) throws -> Int,
                                      hostBound: (Int, Int) throws -> Int) throws
        -> (boundary: Int, logits: Int, wireNative: Int, input: Int, tokenHost: Int, wireHost: Int) {
        let chunk = scope.maximumChunkTokens, elementBytes = c.dtype == "bfloat16" ? 2 : 4
        func native(_ bytes: Int, copies: Int = 1) throws -> Int { try nativeBound(bytes, copies) }
        func host(_ bytes: Int, copies: Int = 1) throws -> Int { try hostBound(bytes, copies) }
        let payload = try product([chunk, c.hcMult, c.hiddenSize, elementBytes])
        guard payload <= CollectivePointToPointShape.authenticatedArrayByteLimit,
              transport.maximumRecordPlaintextBytes > 0,
              transport.maximumRecordPlaintextBytes <= CollectiveAuthenticatedRecords.chunkBytes,
              transport.maximumControlBytes >= QwenLayerStageGenerationBoundaryPacket.maximumEncodedBytes,
              transport.maximumControlBytes <= transport.maximumRecordPlaintextBytes,
              transport.maximumTransportFrameBytes <= CollectivePointToPointShape.hardByteLimit else {
            throw ProbeError("GLM transport terms do not cover the residual/control geometry")
        }
        let record = try ClusterRecordTransferAccounting(
            length: .bounded(maximum: max(min(payload, transport.maximumRecordPlaintextBytes), transport.maximumControlBytes)),
            maximumTransportFrameBytes: transport.maximumTransportFrameBytes)
        // Producer + transfer/receiver storage. A final row can keep the whole
        // [1,chunk,vocab] logits allocation alive: never price only that row.
        let boundary = try native(payload, copies: 2)
        let logits = rank == 1 ? try native(product([chunk, c.vocabularySize, 4]), copies: 2) : 0
        let wireNative = try sum([native(record.maximumSealedRecordBytes, copies: 2),
            native(transport.maximumControlBytes, copies: 2)])
        let input = try sum([native(product([chunk, 4]), copies: 2), native(chunk, copies: 2)])
        let tokenHost = try host(product([scope.maximumContextTokens, MemoryLayout<Int>.stride]), copies: 2)
        // Full plaintext snapshot/assembly; chunk slice, codec ciphertext,
        // sealed record and bounded framing copies may coexist. CryptoKit's
        // opaque scratch and extra Foundation capacity require external evidence.
        let wireHost = try sum([
            host(max(payload, transport.maximumControlBytes), copies: 2), host(record.maximumPlaintextBytes),
            host(record.codecCiphertextAndTagLogicalBytes),
            host(record.maximumSealedRecordBytes, copies: 2),
            host(record.additionalFramingDataBytes),
        ])
        return (boundary, logits, wireNative, input, tokenHost, wireHost)
    }

    /// Shared with preliminary placement; admission independently bounds every
    /// actual allocation. Settled current/rollback states are compact only after
    /// the SDK transaction fences all retained roots. Six pairs cover committed,
    /// copied and next owners without assuming aliasing or donation. Contiguous
    /// may retain a backing buffer up to 16 KiB larger than its logical output.
    /// Two full FP32 histories per layer cover the pending K+chunk history and
    /// its cast while compaction evaluates. Opaque graph/kernel workspace,
    /// prefix snapshots and all non-KDA terms remain separately reserved.
    static func linearTransactionBytes(configuration linear: GLM5NextLinearAttentionConfiguration,
                                       chunk: Int,
                                       native: (Int, Int) throws -> Int) throws -> Int {
        let channels = try product([3, linear.numHeads, linear.headDim])
        let compactConvolution = try sum([product([channels, linear.shortConvKernelSize, 4]), 16_384])
        let compactRecurrent = try sum([product([linear.numHeads, linear.headDim, linear.headDim, 4]), 16_384])
        let pendingHistory = try product([channels, sum([linear.shortConvKernelSize, chunk]), 4])
        return try sum([native(compactConvolution, 6), native(compactRecurrent, 6), native(pendingHistory, 2)])
    }

    static func sum(_ values: [Int]) throws -> Int { try GLM5NextStageLoadResources.sum(values) }
    static func product(_ values: [Int]) throws -> Int {
        try values.reduce(1) { total, value in
            let result = total.multipliedReportingOverflow(by: value)
            guard value > 0, !result.overflow else { throw ProbeError("GLM request byte product overflow") }
            return result.partialValue
        }
    }
}
