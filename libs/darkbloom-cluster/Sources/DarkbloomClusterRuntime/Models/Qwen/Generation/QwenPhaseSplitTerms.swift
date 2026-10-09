import Foundation

/// One request-state component by identity only: no bytes and no digest.
struct QwenPhaseSplitStateShape: Codable, Equatable {
    static let positionOffsets = "kv.position_offsets"
    let globalLayerIndex: Int
    let component: String
    let shape: [Int]
    let dtype: String
    let byteCount: Int

    var identity: String { "\(globalLayerIndex)|\(component)|\(shape)|\(dtype)|\(byteCount)" }

    static func elementBytes(_ dtype: String) throws -> Int {
        switch dtype {
        case "float16", "bfloat16": return 2
        case "float32", "int32": return 4
        default: throw ProbeError("Phase-split state dtype is not an admitted native type")
        }
    }
}

/// One point-to-point transfer of the hand-off. An entry larger than the
/// agreed segment limit is cut along its token axis; nothing else is cut.
struct QwenPhaseSplitSegment: Equatable {
    let entryIndex: Int
    /// Token range along axis 2 of a cut attention tensor; nil for a whole entry.
    let tokens: Range<Int>?
    let shape: [Int]
    let dtype: String
    let byteCount: Int
}

/// What both ranks commit to before a phase-split request starts. It is part of
/// the generation agreement, so its fingerprint is exchanged in the existing
/// readiness step and a rank that derives anything else stops before any state
/// exists on either side.
struct QwenPhaseSplitTerms: Encodable, Equatable {
    static let maximumRelayBatchTokens = 32
    static let defaultRelayBatchTokens = 16
    static let defaultHandoffLimitMilliseconds = 20_000

    let schema = "qwen_stage_phase_split_v1"
    /// The hand-off follows the last prompt frame and the first selected token.
    let handoffCommittedTokens: Int
    let handoffSelectedTokens = 1
    /// Layers [0, producerLayerCount) change owner; the adopting rank holds all layers.
    let producerLayerCount: Int
    let entryCount: Int
    let logicalBytes: Int
    let manifestSHA256: String
    let maximumSegmentBytes: Int
    let segmentCount: Int
    let relayBatchTokens: Int
    let handoffLimitMilliseconds: Int
}

/// The terms and the local expectation they were derived from. Every receive
/// allocation of a hand-off comes from `shapes`, never from a received header.
struct QwenPhaseSplitPlan: Equatable {
    let terms: QwenPhaseSplitTerms
    let shapes: [QwenPhaseSplitStateShape]
    let segments: [QwenPhaseSplitSegment]

    init(plan: QwenLayerStagePlan, geometry: QwenLongPrefillBudgetGeometry,
         request: QwenLayerStageGenerationRequest,
         maximumSegmentBytes: Int = CollectivePointToPointShape.hardByteLimit,
         relayBatchTokens: Int = QwenPhaseSplitTerms.defaultRelayBatchTokens,
         handoffLimitMilliseconds: Int = QwenPhaseSplitTerms.defaultHandoffLimitMilliseconds) throws {
        guard plan.stages.count == 2, plan.layers == geometry.layers, plan.interval == geometry.fullAttentionInterval,
              (4096...CollectivePointToPointShape.hardByteLimit).contains(maximumSegmentBytes),
              (1...QwenPhaseSplitTerms.maximumRelayBatchTokens).contains(relayBatchTokens),
              (1000...120_000).contains(handoffLimitMilliseconds) else {
            throw ProbeError("Phase split requires the admitted two-stage Plan and bounded terms")
        }
        let shapes = try Self.expectedShapes(stage: plan.stages[0], geometry: geometry,
            committedTokens: request.promptCount, activationDType: request.profile.activationDType)
        let segments = try Self.segments(shapes, maximumSegmentBytes: maximumSegmentBytes)
        // One header names every component. Whether it fits its fixed frame
        // depends on the model's layer count and the cut, so it is settled
        // here, with the terms, and not when the header is first written.
        guard try QwenPhaseSplitHandoffHeader.encodedBytesBound(shapes: shapes)
                <= QwenPhaseSplitHandoffHeader.frameBytes - QwenControlFrame.headerBytes else {
            throw ProbeError("Phase split: this model and cut name more state components than one hand-off header holds")
        }
        self.shapes = shapes; self.segments = segments
        terms = .init(handoffCommittedTokens: request.promptCount,
            producerLayerCount: plan.stages[0].sourceRange.count, entryCount: shapes.count,
            logicalBytes: try QwenLongPrefillCheckedBytes.sum(shapes.map(\.byteCount)),
            manifestSHA256: sha256(Data((["qwen-phase-split-manifest-v1", "tokens=\(request.promptCount)"]
                + shapes.map(\.identity)).joined(separator: "\n").utf8)),
            maximumSegmentBytes: maximumSegmentBytes, segmentCount: segments.count,
            relayBatchTokens: relayBatchTokens, handoffLimitMilliseconds: handoffLimitMilliseconds)
    }

    /// The producer stage's committed state after `committedTokens` tokens, in
    /// the order a state snapshot lists it. Derived from the registered
    /// geometry and the Plan; the producer's actual snapshot must equal it.
    static func expectedShapes(stage: QwenLayerStagePlan.Stage, geometry g: QwenLongPrefillBudgetGeometry,
                               committedTokens: Int, activationDType: String) throws -> [QwenPhaseSplitStateShape] {
        guard stage.index == 0, stage.sourceRange.lowerBound == 0, !stage.layers.isEmpty,
              (1...32_768).contains(committedTokens) else {
            throw ProbeError("Phase split hands over the producer stage after a committed prompt")
        }
        let product = QwenLongPrefillCheckedBytes.product, sum = QwenLongPrefillCheckedBytes.sum
        let element = try QwenPhaseSplitStateShape.elementBytes(activationDType)
        guard element == 2 || activationDType == "float32" else { throw ProbeError("Phase-split activation dtype is not floating point") }
        let channels = try sum([product([2, g.linearKeyHeads, g.linearKeyDimension]),
                                product([g.linearValueHeads, g.linearValueDimension])])
        let kvShape = [1, g.kvHeads, committedTokens, g.headDimension]
        let convShape = [1, g.convolutionKernel - 1, channels]
        let ssmShape = [1, g.linearValueHeads, g.linearValueDimension, g.linearKeyDimension]
        var shapes: [QwenPhaseSplitStateShape] = []
        for layer in stage.layers.sorted(by: { $0.globalIndex < $1.globalIndex }) {
            switch layer.kind {
            case "full_attention":
                let bytes = try product(kvShape + [element])
                shapes.append(.init(globalLayerIndex: layer.globalIndex, component: "kv.keys",
                    shape: kvShape, dtype: activationDType, byteCount: bytes))
                shapes.append(.init(globalLayerIndex: layer.globalIndex, component: QwenPhaseSplitStateShape.positionOffsets,
                    shape: [1], dtype: "int32", byteCount: 4))
                shapes.append(.init(globalLayerIndex: layer.globalIndex, component: "kv.values",
                    shape: kvShape, dtype: activationDType, byteCount: bytes))
            case "linear_attention":
                shapes.append(.init(globalLayerIndex: layer.globalIndex, component: "conv",
                    shape: convShape, dtype: activationDType, byteCount: try product(convShape + [element])))
                shapes.append(.init(globalLayerIndex: layer.globalIndex, component: "ssm",
                    shape: ssmShape, dtype: "float32", byteCount: try product(ssmShape + [4])))
            default: throw ProbeError("Phase split has an unsupported layer policy")
            }
        }
        return shapes
    }

    /// Position offsets are a function of the committed frontier and are
    /// checked by digest, not sent. An empty component is not sent either.
    static func segments(_ shapes: [QwenPhaseSplitStateShape], maximumSegmentBytes: Int) throws -> [QwenPhaseSplitSegment] {
        guard maximumSegmentBytes > 0 else { throw ProbeError("Phase-split segment limit must be positive") }
        var result: [QwenPhaseSplitSegment] = []
        for (index, entry) in shapes.enumerated() {
            guard entry.component != QwenPhaseSplitStateShape.positionOffsets, entry.byteCount > 0 else { continue }
            if entry.byteCount <= maximumSegmentBytes {
                result.append(.init(entryIndex: index, tokens: nil, shape: entry.shape, dtype: entry.dtype, byteCount: entry.byteCount))
                continue
            }
            let element = try QwenPhaseSplitStateShape.elementBytes(entry.dtype)
            guard entry.component.hasPrefix("kv."), entry.shape.count == 4, entry.shape[0] == 1 else {
                throw ProbeError("Only an attention tensor may exceed the hand-off segment limit")
            }
            let perToken = try QwenLongPrefillCheckedBytes.product([entry.shape[1], entry.shape[3], element])
            let step = maximumSegmentBytes / perToken
            guard step > 0 else { throw ProbeError("Hand-off segment limit is smaller than one token of attention state") }
            var start = 0
            while start < entry.shape[2] {
                let end = min(entry.shape[2], start + step)
                result.append(.init(entryIndex: index, tokens: start..<end,
                    shape: [1, entry.shape[1], end - start, entry.shape[3]], dtype: entry.dtype,
                    byteCount: (end - start) * perToken))
                start = end
            }
        }
        return result
    }
}

/// Named storage for the hand-off itself, charged on top of the unchanged
/// request allowance: the bytes in flight on each side and, on the adopting
/// rank, the fusion of the producer stage it also holds. Not a process bound.
struct QwenPhaseSplitAllowance: Encodable, Equatable {
    let rank: Int
    let extraNativeBytes: Int
    let extraHostBytes: Int
    var reservedBytes: Int { get throws { try QwenLongPrefillCheckedBytes.sum([extraNativeBytes, extraHostBytes]) } }

    static func derive(rank: Int, shapes: [QwenPhaseSplitStateShape], producerFusionBytes: Int,
                       bound: (Int) throws -> Int) throws -> Self {
        guard (0...1).contains(rank), !shapes.isEmpty, producerFusionBytes >= 0 else {
            throw ProbeError("Invalid phase-split allowance geometry")
        }
        var native = 0, host = 0
        for entry in shapes where entry.byteCount > 0 {
            let rounded = try bound(entry.byteCount)
            guard rounded >= entry.byteCount else { throw ProbeError("Phase-split allocator bound is too small") }
            native = try QwenLongPrefillCheckedBytes.sum([native, rounded])
            host = try QwenLongPrefillCheckedBytes.sum([host, entry.byteCount])
        }
        return .init(rank: rank,
            extraNativeBytes: try QwenLongPrefillCheckedBytes.sum([native, rank == 1 ? producerFusionBytes : 0]),
            extraHostBytes: host)
    }
}

/// A fault a qualification run asks a rank to commit during the hand-off, so
/// that the failure paths can be exercised on real state. It is read from the
/// environment only by a process that was started with the explicit test flag
/// (`QwenResidentQualificationSwitches`), and honoured only for a recording
/// request, which is itself qualification only; a serving request never sees one.
struct QwenPhaseSplitFault: Equatable {
    static let environmentName = QwenResidentQualificationSwitches.faultEnvironmentName
    /// Rank 0: flip one bit of this segment after its digest was computed.
    var corruptSegment: Int?
    /// Rank 1: stop for this long after receiving this segment, still checking
    /// its deadline, as a rank that has stalled would.
    var stallAfterSegment: Int?
    var stallMilliseconds = 0

    /// `handoff_corrupt_segment=N` or `handoff_stall_after_segment=N:MILLISECONDS`.
    static func admit(environment: [String: String]) throws -> Self? {
        guard let text = environment[environmentName] else { return nil }
        let parts = text.split(separator: "=", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw ProbeError("Unknown \(environmentName)") }
        func number(_ value: Substring, _ range: ClosedRange<Int>) throws -> Int {
            guard let result = Int(value), String(result) == value, range.contains(result) else {
                throw ProbeError("\(environmentName) has an invalid number")
            }
            return result
        }
        switch parts[0] {
        case "handoff_corrupt_segment":
            return Self(corruptSegment: try number(parts[1], 0...4096))
        case "handoff_stall_after_segment":
            let values = parts[1].split(separator: ":", omittingEmptySubsequences: false)
            guard values.count == 2 else { throw ProbeError("\(environmentName) stall needs SEGMENT:MILLISECONDS") }
            return Self(stallAfterSegment: try number(values[0], 0...4096),
                        stallMilliseconds: try number(values[1], 1...600_000))
        default: throw ProbeError("Unknown \(environmentName)")
        }
    }
}

/// What a phase-split request did, for the result record and one diagnostic
/// line. Byte counts are MLX's own active and cached totals for this process.
struct QwenPhaseSplitSummary: Encodable, Equatable {
    struct Memory: Encodable, Equatable {
        let activeBytes: Int
        let cacheBytes: Int
    }
    let rank: Int
    let handoffPerformed: Bool
    let handoffEntries: Int
    let handoffSegments: Int
    let handoffLogicalBytes: Int
    /// This rank's wall time from the start of its export or receive to the accepted acknowledgement.
    let handoffNanoseconds: UInt64
    /// Rank 0: snapshot and digests. Rank 1: adoption after the last segment.
    let handoffLocalStateNanoseconds: UInt64
    let relayBatches: Int
    let soloDecodeForwards: Int
    let discardedDecodeForwards: Int
    let beforeHandoff: Memory
    let afterHandoff: Memory
    let afterRetirement: Memory
}
