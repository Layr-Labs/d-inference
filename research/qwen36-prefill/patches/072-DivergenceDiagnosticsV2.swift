// DivergenceDiagnosticsV2.swift
//
// Temporary, environment-gated E40/E41 diagnostics. This file is carried in
// an ordered research patch and must not ship after the parity issue is fixed.

import Foundation
import MLX

public enum CBv2DivergenceDiagnostics {
    public struct BatchRegistration: Sendable {
        public let requestIDBase: UInt64
        public let count: Int
        public let phase: String
        public let scenario: String
        public let iteration: Int

        public init(
            requestIDBase: UInt64,
            count: Int,
            phase: String,
            scenario: String,
            iteration: Int
        ) {
            self.requestIDBase = requestIDBase
            self.count = count
            self.phase = phase
            self.scenario = scenario
            self.iteration = iteration
        }
    }

    struct Assignment {
        let id: CBv2RequestID
        let start: Int
        let count: Int
        let generatedTokens: Int
        let promptTokens: Int
        let pendingSamples: Int
        let exactSnapshotBlockSize: Int?
    }

    struct ArrayProbe {
        let label: String
        let array: MLXArray
        let checksum: MLXArray

        init(label: String, array: MLXArray) {
            self.label = label
            self.array = array
            let flat = array.asType(.float32).flattened()
            if flat.size == 0 {
                checksum = MLXArray.zeros([8], dtype: .float32)
            } else {
                let sampleIndices = [
                    0,
                    flat.size / 4,
                    flat.size / 2,
                    (flat.size * 3) / 4,
                    flat.size - 1,
                ]
                let samples = sampleIndices.map { flat[$0].reshaped([1]) }
                checksum = concatenated(
                    [
                        flat.sum().reshaped([1]),
                        (flat * flat).sum().reshaped([1]),
                        MLX.abs(flat).max().reshaped([1]),
                    ] + samples,
                    axis: 0)
            }
        }

        var evaluationArrays: [MLXArray] { [checksum] }

        func payload() -> [String: Any] {
            let values = checksum.asArray(Float.self).map(jsonFloat)
            return [
                "label": label,
                "shape": array.shape,
                "strides": array.strides,
                "dtype": String(describing: array.dtype),
                "logicalBytes": array.nbytes,
                "checksum": [
                    "sum": values[0],
                    "sumSquares": values[1],
                    "maxAbs": values[2],
                    "samples": Array(values[3...]),
                ] as [String: Any],
            ]
        }
    }

    struct KVProbe {
        let storageIndex: Int
        let modelLayerIndex: Int
        let offset: Int
        let retainedCount: Int
        let byteCount: Int
        let keys: ArrayProbe
        let values: ArrayProbe
        let backing: [MLXArray]

        var evaluationArrays: [MLXArray] {
            keys.evaluationArrays + values.evaluationArrays
        }

        func payload() -> [String: Any] {
            [
                "storageIndex": storageIndex,
                "modelLayerIndex": modelLayerIndex,
                "offset": offset,
                "retainedCount": retainedCount,
                "byteCount": byteCount,
                "keys": keys.payload(),
                "values": values.payload(),
                "storage": backing.enumerated().map { index, array in
                    [
                        "component": index == 0 ? "keys" : "values",
                        "shape": array.shape,
                        "strides": array.strides,
                        "dtype": String(describing: array.dtype),
                        "logicalBytes": array.nbytes,
                        "tokenCapacity": array.ndim > 2 ? array.dim(2) : -1,
                    ] as [String: Any]
                },
            ]
        }
    }

    struct StateProbe {
        let kv: [KVProbe]
        let recurrent: [ArrayProbe]

        var evaluationArrays: [MLXArray] {
            kv.flatMap(\.evaluationArrays) + recurrent.flatMap(\.evaluationArrays)
        }

        func payload() -> [String: Any] {
            [
                "kv": kv.map { $0.payload() },
                "recurrent": recurrent.map { $0.payload() },
            ]
        }
    }

    struct LogitsProbe {
        let checksum: ArrayProbe
        let indices: MLXArray
        let values: MLXArray

        init(_ logits: MLXArray) {
            let row = logits.flattened()
            checksum = ArrayProbe(label: "logits", array: row)
            let count = min(5, row.size)
            let candidates = argPartition(-row, kth: max(0, count - 1), axis: 0)[0 ..< count]
                .asType(.int32)
            indices = candidates
            values = takeAlong(row, candidates, axis: 0).asType(.float32)
        }

        var evaluationArrays: [MLXArray] {
            checksum.evaluationArrays + [indices, values]
        }

        func payload() -> [String: Any] {
            let ranked = zip(
                indices.asArray(Int32.self),
                values.asArray(Float.self)
            ).sorted { $0.1 > $1.1 }
            return [
                "summary": checksum.payload(),
                "topRanks": ranked.enumerated().map { rank, pair in
                    [
                        "rank": rank + 1,
                        "tokenID": Int(pair.0),
                        "value": jsonFloat(pair.1),
                    ] as [String: Any]
                },
            ]
        }
    }

    final class Frame {
        let registration: Registration
        let requestID: CBv2RequestID
        let engineStep: Int
        let path: String
        let cohortSize: Int
        let assignmentCount: Int
        let modelInputStart: Int
        let modelInputCount: Int
        let generatedTokens: Int
        let promptTokens: Int
        let positionOffsetBefore: Int
        let positionMode: String
        let effectivePositionIDs: [Int]
        let explicitPositionIDs: ArrayProbe?
        let stateBefore: StateProbe?
        let stateAfter: StateProbe
        let logits: LogitsProbe

        init(
            registration: Registration,
            requestID: CBv2RequestID,
            engineStep: Int,
            path: String,
            cohortSize: Int,
            assignmentCount: Int,
            modelInputStart: Int,
            modelInputCount: Int,
            generatedTokens: Int,
            promptTokens: Int,
            positionOffsetBefore: Int,
            positionMode: String,
            effectivePositionIDs: [Int],
            explicitPositionIDs: ArrayProbe?,
            stateBefore: StateProbe?,
            stateAfter: StateProbe,
            logits: LogitsProbe
        ) {
            self.registration = registration
            self.requestID = requestID
            self.engineStep = engineStep
            self.path = path
            self.cohortSize = cohortSize
            self.assignmentCount = assignmentCount
            self.modelInputStart = modelInputStart
            self.modelInputCount = modelInputCount
            self.generatedTokens = generatedTokens
            self.promptTokens = promptTokens
            self.positionOffsetBefore = positionOffsetBefore
            self.positionMode = positionMode
            self.effectivePositionIDs = effectivePositionIDs
            self.explicitPositionIDs = explicitPositionIDs
            self.stateBefore = stateBefore
            self.stateAfter = stateAfter
            self.logits = logits
        }

        var evaluationArrays: [MLXArray] {
            (stateBefore?.evaluationArrays ?? [])
                + stateAfter.evaluationArrays
                + (explicitPositionIDs?.evaluationArrays ?? [])
                + logits.evaluationArrays
        }
    }

    struct Registration {
        let phase: String
        let scenario: String
        let iteration: Int
        let row: Int
        let cohortSize: Int
    }

    public static let enabled =
        ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_DIVERGENCE_DEBUG"] == "1"

    private static let scenarioFilter =
        ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_DIVERGENCE_SCENARIO"]
    private static let maxDecodeStep =
        ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_DIVERGENCE_MAX_DECODE_STEP"]
        .flatMap(Int.init) ?? 6
    private static let forcedPrefillChunkTokensEnvironmentValue =
        ProcessInfo.processInfo.environment[
            "DARKBLOOM_PREFIX_DIVERGENCE_FORCE_CHUNK_TOKENS"
        ]
    private static let forceUnpackedPrefillEnvironmentValue =
        ProcessInfo.processInfo.environment[
            "DARKBLOOM_PREFIX_DIVERGENCE_FORCE_UNPACKED_PREFILL"
        ]
    static let forcedPrefillChunkTokens: Int? =
        enabled
        ? forcedPrefillChunkTokensEnvironmentValue.flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
        : nil
    static let forcesUnpackedPrefill =
        enabled
        && forceUnpackedPrefillEnvironmentValue == "1"
    private static let logPath = "/opt/cursor/logs/debug.log"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var registrations: [CBv2RequestID: Registration] = [:]

    public static func registerBatch(_ batch: BatchRegistration) {
        guard enabled, batch.count > 0 else { return }
        lock.lock()
        for row in 0 ..< batch.count {
            registrations[CBv2RequestID(batch.requestIDBase + UInt64(row))] = Registration(
                phase: batch.phase,
                scenario: batch.scenario,
                iteration: batch.iteration,
                row: row,
                cohortSize: batch.count)
        }
        lock.unlock()
        guard scenarioFilter == nil || scenarioFilter == batch.scenario else { return }
        // #region agent log
        append(
            hypothesisID: "D",
            location: "QwenPrefixReuseBenchmark.swift:registerDiagnosticBatch",
            message: "benchmark phase request map",
            data: [
                "phase": batch.phase,
                "scenario": batch.scenario,
                "iteration": batch.iteration,
                "requestIDBase": String(batch.requestIDBase),
                "cohortSize": batch.count,
            ])
        // #endregion
        // #region agent log
        append(
            hypothesisID: "H1,H2",
            location: "DivergenceDiagnosticsV2.swift:registerBatch",
            message: "diagnostic prefill posture control configuration",
            data: [
                "instrumentationRevision": "e45-prefill-control-proof-v1",
                "phase": batch.phase,
                "scenario": batch.scenario,
                "iteration": batch.iteration,
                "forcedPrefillChunkTokensEnvironmentValue":
                    forcedPrefillChunkTokensEnvironmentValue.map { $0 as Any } ?? NSNull(),
                "forceUnpackedPrefillEnvironmentValue":
                    forceUnpackedPrefillEnvironmentValue.map { $0 as Any } ?? NSNull(),
                "forcedPrefillChunkTokens":
                    forcedPrefillChunkTokens.map { $0 as Any } ?? NSNull(),
                "forcesUnpackedPrefill": forcesUnpackedPrefill,
            ])
        // #endregion
    }

    static func recordSchedule(
        engineStep: Int,
        assignments: [Assignment],
        packedPrefillSupported: Bool
    ) {
        guard enabled else { return }
        let rows = assignments.compactMap { assignment -> [String: Any]? in
            guard let registration = registration(for: assignment.id) else { return nil }
            return [
                "requestID": String(assignment.id.raw),
                "phase": registration.phase,
                "scenario": registration.scenario,
                "iteration": registration.iteration,
                "row": registration.row,
                "start": assignment.start,
                "count": assignment.count,
                "generatedTokens": assignment.generatedTokens,
                "promptTokens": assignment.promptTokens,
                "pendingSamples": assignment.pendingSamples,
                "exactSnapshotBlockSize":
                    assignment.exactSnapshotBlockSize.map { $0 as Any } ?? NSNull(),
            ]
        }
        guard !rows.isEmpty else { return }
        // #region agent log
        append(
            hypothesisID: "B,D",
            location: "EngineLoopV2.swift:engineStep",
            message: "scheduler step assignments",
            data: [
                "engineStep": engineStep,
                "assignmentCount": assignments.count,
                "stepBatchSize": rows.count,
                "packedPrefillSupported": packedPrefillSupported,
                "rows": rows,
            ])
        // #endregion
    }

    static func recordAdoption(
        requestID: CBv2RequestID,
        matched: Int,
        snapshot: CBv2ExactPrefixSnapshot,
        adoptedState: [CBv2SequenceKV?],
        recurrent: CBv2RecurrentRequestState,
        layerKinds: [CBv2LayerKind]
    ) {
        guard let registration = registration(for: requestID) else { return }
        let snapshotRows = snapshot.attention.enumerated().compactMap {
            index, entry -> [String: Any]? in
            guard let entry else { return nil }
            return [
                "storageIndex": index,
                "modelLayerIndex": layerKinds[index].modelLayerIndex ?? index,
                "offset": entry.offset,
                "keyShape": entry.keys.shape,
                "keyStrides": entry.keys.strides,
                "valueShape": entry.values.shape,
                "valueStrides": entry.values.strides,
                "keyBytes": entry.keys.nbytes,
                "valueBytes": entry.values.nbytes,
            ]
        }
        let adoptedRows = adoptedState.enumerated().compactMap {
            index, sequence -> [String: Any]? in
            guard let sequence else { return nil }
            let visible = sequence.snapshot()
            let backing = (sequence as? CBv2InnerStateProviding)?.cbv2InnerState() ?? []
            return [
                "storageIndex": index,
                "modelLayerIndex": layerKinds[index].modelLayerIndex ?? index,
                "offset": visible.offset,
                "keyShape": visible.keys.shape,
                "keyStrides": visible.keys.strides,
                "valueShape": visible.values.shape,
                "valueStrides": visible.values.strides,
                "storageShapes": backing.map(\.shape),
                "storageStrides": backing.map(\.strides),
                "tokenCapacities": backing.map { $0.ndim > 2 ? $0.dim(2) : -1 },
            ]
        }
        let snapshotRecurrent = snapshot.recurrentState.spec.layers.flatMap {
            spec -> [[String: Any]] in
            guard let layer = snapshot.recurrentState.layers[spec.modelLayerIndex] else {
                return []
            }
            return [
                layer.conv.map {
                    [
                        "modelLayerIndex": spec.modelLayerIndex,
                        "component": "conv",
                        "shape": $0.shape,
                        "strides": $0.strides,
                        "dtype": String(describing: $0.dtype),
                        "logicalBytes": $0.nbytes,
                    ] as [String: Any]
                },
                layer.ssm.map {
                    [
                        "modelLayerIndex": spec.modelLayerIndex,
                        "component": "ssm",
                        "shape": $0.shape,
                        "strides": $0.strides,
                        "dtype": String(describing: $0.dtype),
                        "logicalBytes": $0.nbytes,
                    ] as [String: Any]
                },
            ].compactMap { $0 }
        }
        let restoredRecurrent = recurrent.spec.layers.flatMap {
            spec -> [[String: Any]] in
            guard let layer = recurrent.state(modelLayerIndex: spec.modelLayerIndex) else {
                return []
            }
            return [
                layer.conv.map {
                    [
                        "modelLayerIndex": spec.modelLayerIndex,
                        "component": "conv",
                        "shape": $0.shape,
                        "strides": $0.strides,
                        "dtype": String(describing: $0.dtype),
                        "logicalBytes": $0.nbytes,
                    ] as [String: Any]
                },
                layer.ssm.map {
                    [
                        "modelLayerIndex": spec.modelLayerIndex,
                        "component": "ssm",
                        "shape": $0.shape,
                        "strides": $0.strides,
                        "dtype": String(describing: $0.dtype),
                        "logicalBytes": $0.nbytes,
                    ] as [String: Any]
                },
            ].compactMap { $0 }
        }
        // #region agent log
        append(
            hypothesisID: "A,C,E",
            location: "EngineLoopV2.swift:applyAdoption",
            message: "exact snapshot adopted into fresh request state",
            data: [
                "requestID": String(requestID.raw),
                "phase": registration.phase,
                "scenario": registration.scenario,
                "iteration": registration.iteration,
                "row": registration.row,
                "matched": matched,
                "snapshotKV": snapshotRows,
                "adoptedKV": adoptedRows,
                "snapshotRecurrentBytes": snapshot.recurrentState.byteCount,
                "restoredRecurrentBytes": recurrent.byteCount,
                "snapshotRecurrent": snapshotRecurrent,
                "restoredRecurrent": restoredRecurrent,
            ])
        // #endregion
    }

    static func makeFrame(
        requestID: CBv2RequestID,
        engineStep: Int,
        path: String,
        cohortSize: Int,
        assignmentCount: Int,
        modelInputStart: Int,
        modelInputCount: Int,
        generatedTokens: Int,
        promptTokens: Int,
        positionOffsetBefore: Int,
        positionIDs: MLXArray?,
        stateBefore: StateProbe? = nil,
        layerKinds: [CBv2LayerKind],
        state: [CBv2SequenceKV?],
        recurrent: CBv2RecurrentRequestState,
        logits: MLXArray
    ) -> Frame? {
        guard let registration = registration(for: requestID) else { return nil }
        let decodeStep = max(0, modelInputStart - promptTokens + 1)
        guard decodeStep <= maxDecodeStep else { return nil }
        let explicitPositionIDs = positionIDs.map {
            ArrayProbe(label: "positionIDs", array: $0)
        }
        let effectivePositionIDs =
            positionIDs == nil && modelInputCount > 0
            ? Array(positionOffsetBefore ..< positionOffsetBefore + modelInputCount)
            : []
        return Frame(
            registration: registration,
            requestID: requestID,
            engineStep: engineStep,
            path: path,
            cohortSize: cohortSize,
            assignmentCount: assignmentCount,
            modelInputStart: modelInputStart,
            modelInputCount: modelInputCount,
            generatedTokens: generatedTokens,
            promptTokens: promptTokens,
            positionOffsetBefore: positionOffsetBefore,
            positionMode: positionIDs == nil
                ? "scalar-cache-offset"
                : "explicit-\(positionIDs!.shape)",
            effectivePositionIDs: effectivePositionIDs,
            explicitPositionIDs: explicitPositionIDs,
            stateBefore: stateBefore,
            stateAfter: stateProbe(layerKinds: layerKinds, state: state, recurrent: recurrent),
            logits: LogitsProbe(logits))
    }

    static func captureState(
        requestID: CBv2RequestID,
        modelInputStart: Int,
        promptTokens: Int,
        layerKinds: [CBv2LayerKind],
        state: [CBv2SequenceKV?],
        recurrent: CBv2RecurrentRequestState
    ) -> StateProbe? {
        guard registration(for: requestID) != nil else { return nil }
        let decodeStep = max(0, modelInputStart - promptTokens + 1)
        guard decodeStep <= maxDecodeStep else { return nil }
        return stateProbe(layerKinds: layerKinds, state: state, recurrent: recurrent)
    }

    static func record(_ frame: Frame) {
        // #region agent log
        append(
            hypothesisID: "A,B,C,D,E",
            location: "EngineLoopV2.swift:finalize",
            message: "evaluated model boundary and logits",
            data: [
                "requestID": String(frame.requestID.raw),
                "phase": frame.registration.phase,
                "scenario": frame.registration.scenario,
                "iteration": frame.registration.iteration,
                "row": frame.registration.row,
                "registeredCohortSize": frame.registration.cohortSize,
                "engineStep": frame.engineStep,
                "path": frame.path,
                "stepCohortSize": frame.cohortSize,
                "assignmentCount": frame.assignmentCount,
                "modelInputStart": frame.modelInputStart,
                "modelInputCount": frame.modelInputCount,
                "generatedTokensBefore": frame.generatedTokens,
                "promptTokens": frame.promptTokens,
                "positionMode": frame.positionMode,
                "positionOffsetBefore": frame.positionOffsetBefore,
                "effectivePositionIDs": frame.effectivePositionIDs,
                "explicitPositionIDs": frame.explicitPositionIDs?.payload() ?? NSNull(),
                "stateBefore": frame.stateBefore?.payload() ?? NSNull(),
                "stateAfter": frame.stateAfter.payload(),
                "logits": frame.logits.payload(),
            ])
        // #endregion
    }

    private static func stateProbe(
        layerKinds: [CBv2LayerKind],
        state: [CBv2SequenceKV?],
        recurrent: CBv2RecurrentRequestState
    ) -> StateProbe {
        let kv = state.enumerated().compactMap { index, sequence -> KVProbe? in
            guard let sequence else { return nil }
            let visible = sequence.snapshot()
            return KVProbe(
                storageIndex: index,
                modelLayerIndex: layerKinds[index].modelLayerIndex ?? index,
                offset: visible.offset,
                retainedCount: sequence.retainedCount,
                byteCount: sequence.byteCount,
                keys: ArrayProbe(label: "kv.\(index).keys", array: visible.keys),
                values: ArrayProbe(label: "kv.\(index).values", array: visible.values),
                backing: (sequence as? CBv2InnerStateProviding)?.cbv2InnerState() ?? [])
        }
        let recurrentProbes = recurrent.spec.layers.flatMap { spec -> [ArrayProbe] in
            guard let layer = recurrent.state(modelLayerIndex: spec.modelLayerIndex) else {
                return []
            }
            return [
                layer.conv.map {
                    ArrayProbe(label: "recurrent.\(spec.modelLayerIndex).conv", array: $0)
                },
                layer.ssm.map {
                    ArrayProbe(label: "recurrent.\(spec.modelLayerIndex).ssm", array: $0)
                },
            ].compactMap { $0 }
        }
        return StateProbe(kv: kv, recurrent: recurrentProbes)
    }

    private static func registration(for id: CBv2RequestID) -> Registration? {
        guard enabled else { return nil }
        lock.lock()
        let registration = registrations[id]
        lock.unlock()
        guard let registration,
            scenarioFilter == nil || scenarioFilter == registration.scenario
        else { return nil }
        return registration
    }

    private static func append(
        hypothesisID: String,
        location: String,
        message: String,
        data: [String: Any]
    ) {
        let payload: [String: Any] = [
            "hypothesisId": hypothesisID,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Int64(Date().timeIntervalSince1970 * 1_000),
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var line = encoded
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: logPath) {
            _ = FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: logPath) else { return }
        handle.seekToEndOfFile()
        handle.write(line)
        try? handle.close()
    }

    private static func jsonFloat(_ value: Float) -> Any {
        value.isFinite ? Double(value) : String(describing: value)
    }
}
