import Darwin
import Foundation

private final class JSONLinesWriter {
    private let handle: FileHandle

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? handle.close()
    }

    func write(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0a]))
    }
}

private struct AggregateSummary {
    var tensorCount = 0
    var expertTensorCount = 0
    var denseTensorCount = 0
    var matrixCount = 0
    var expertMatrixCount = 0
    var denseMatrixCount = 0
    var rankPassCount = 0
    var rankFailureCount = 0
    var exactRankCount = 0
    var rankGF3Count = 0
    var rankGF5Count = 0
    var totalDecodedValues: Int64 = 0
    var totalDecodedZeros: Int64 = 0
    var totalZeroRows: Int64 = 0
    var totalZeroColumns: Int64 = 0
    var totalDuplicateRows: Int64 = 0
    var totalDuplicateColumns: Int64 = 0
    var totalDuplicateGroups: Int64 = 0
    var totalDuplicateExperts: Int64 = 0
    var totalBN32BK8Blocks: Int64 = 0
    var totalZeroBN32BK8Blocks: Int64 = 0
    var baselineMACs = 0.0
    var rankBoundRemovableMACs = 0.0
    var maximumPerMatrixRankDeletionUpperBound = 0.0

    mutating func add(_ audit: TensorAudit) {
        tensorCount += 1
        if audit.tensor.isExpertTensor {
            expertTensorCount += 1
        } else {
            denseTensorCount += 1
        }
        if let experts = audit.expertDuplicates {
            totalDuplicateExperts += Int64(experts.duplicateItems)
        }
        for matrix in audit.matrices {
            matrixCount += 1
            if audit.tensor.isExpertTensor {
                expertMatrixCount += 1
            } else {
                denseMatrixCount += 1
            }
            totalDecodedValues += Int64(audit.tensor.rows * audit.tensor.columns)
            totalDecodedZeros += matrix.decodedZeroCount
            totalZeroRows += Int64(matrix.exactZeroRowCount)
            totalZeroColumns += Int64(matrix.exactZeroColumnCount)
            totalDuplicateRows += Int64(matrix.rowDuplicates.duplicateItems)
            totalDuplicateColumns += Int64(matrix.columnDuplicates.duplicateItems)
            totalDuplicateGroups += Int64(matrix.groupDuplicates.duplicateItems)
            if matrix.rank.rulesOut39Percent {
                rankPassCount += 1
            } else {
                rankFailureCount += 1
            }
            if matrix.rank.status == "exact-rank" { exactRankCount += 1 }
            if matrix.rank.prime == 3 { rankGF3Count += 1 }
            if matrix.rank.prime == 5 { rankGF5Count += 1 }
            let macs = Double(audit.tensor.rows * audit.tensor.columns)
            baselineMACs += macs
            rankBoundRemovableMACs += macs * matrix.rank.macDeletionUpperBound
            maximumPerMatrixRankDeletionUpperBound = max(
                maximumPerMatrixRankDeletionUpperBound,
                matrix.rank.macDeletionUpperBound
            )
            if
                audit.tensor.rows % 32 == 0,
                audit.tensor.columns % 8 == 0
            {
                totalBN32BK8Blocks += Int64(
                    audit.tensor.rows / 32 * audit.tensor.columns / 8
                )
                totalZeroBN32BK8Blocks += matrix.allZeroBlockCounts["32x8"] ?? 0
            }
        }
    }
}

private func main() throws {
    if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--self-test" {
        try runSelfTests()
        print("SELF_TEST=pass")
        return
    }
    guard CommandLine.arguments.count == 3 else {
        throw AuditError.invalid(
            "usage: real-weight-audit SNAPSHOT OUTPUT_DIR | --self-test"
        )
    }

    try runSelfTests()
    let snapshotURL = URL(fileURLWithPath: CommandLine.arguments[1])
        .standardizedFileURL
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
        .standardizedFileURL
    var isDirectory: ObjCBool = false
    guard
        FileManager.default.fileExists(
            atPath: snapshotURL.path,
            isDirectory: &isDirectory
        ),
        isDirectory.boolValue
    else {
        throw AuditError.invalid("snapshot directory is missing: \(snapshotURL.path)")
    }
    try FileManager.default.createDirectory(
        at: outputURL,
        withIntermediateDirectories: true
    )

    let configURL = snapshotURL.appendingPathComponent("config.json")
    let indexURL = snapshotURL.appendingPathComponent("model.safetensors.index.json")
    let configData = try Data(contentsOf: configURL)
    guard
        let config = try JSONSerialization.jsonObject(with: configData)
            as? [String: Any]
    else {
        throw AuditError.invalid("config.json is not an object")
    }
    let resolver = try QuantizationResolver(config: config)
    let index = try SafeTensorIndex(snapshotURL: snapshotURL)

    let u32Tensors = index.tensors.values.filter { $0.dtype == "U32" }
    let weightLocations = u32Tensors
        .filter { $0.name.hasSuffix(".weight") }
        .sorted { $0.name < $1.name }
    guard u32Tensors.count == weightLocations.count else {
        let unsupported = u32Tensors
            .filter { !$0.name.hasSuffix(".weight") }
            .map(\.name)
            .sorted()
        throw AuditError.invalid("unclassified U32 tensors: \(unsupported)")
    }

    let expertTensorCount = weightLocations.filter { $0.shape.count == 3 }.count
    let denseTensorCount = weightLocations.filter { $0.shape.count == 2 }.count
    let expertMatrixCount = weightLocations
        .filter { $0.shape.count == 3 }
        .reduce(0) { $0 + $1.shape[0] }
    guard
        weightLocations.count == 522,
        expertTensorCount == 123,
        denseTensorCount == 399,
        expertMatrixCount == 31_488
    else {
        throw AuditError.invalid(
            "snapshot coverage changed: weights=\(weightLocations.count) "
                + "expert_tensors=\(expertTensorCount) dense_tensors=\(denseTensorCount) "
                + "expert_matrices=\(expertMatrixCount)"
        )
    }

    let matrixWriter = try JSONLinesWriter(
        url: outputURL.appendingPathComponent("matrices.jsonl")
    )
    let tensorWriter = try JSONLinesWriter(
        url: outputURL.appendingPathComponent("tensors.jsonl")
    )
    let progressURL = outputURL.appendingPathComponent("progress.log")
    FileManager.default.createFile(atPath: progressURL.path, contents: nil)
    let progressHandle = try FileHandle(forWritingTo: progressURL)
    defer { try? progressHandle.close() }
    func progress(_ line: String) {
        let complete = "\(iso8601Now()) \(line)\n"
        if let data = complete.data(using: .utf8) {
            try? progressHandle.write(contentsOf: data)
        }
        FileHandle.standardError.write(Data(complete.utf8))
    }

    progress(
        "COVERAGE quantized_tensors=\(weightLocations.count) "
            + "expert_tensors=\(expertTensorCount) dense_tensors=\(denseTensorCount)"
    )

    let collector = RoutedTileCollector()
    var aggregate = AggregateSummary()
    for (ordinal, weightLocation) in weightLocations.enumerated() {
        let base = String(weightLocation.name.dropLast(".weight".count))
        guard let scaleLocation = index.tensors["\(base).scales"] else {
            throw AuditError.invalid("\(base): missing scales tensor")
        }
        let biasLocation = index.tensors["\(base).biases"]
        let policy = try resolver.policy(forWeightBase: base)
        let weight = try MappedTensor(weightLocation)
        let scales = try MappedTensor(scaleLocation)
        let biases = try biasLocation.map { try MappedTensor($0) }
        let tensor = try QuantizedTensor(
            baseName: base,
            weight: weight,
            scales: scales,
            biases: biases,
            policy: policy
        )

        progress(
            "TENSOR_BEGIN ordinal=\(ordinal + 1)/\(weightLocations.count) "
                + "name=\(base) matrices=\(tensor.matrixCount) "
                + "shape=\(tensor.rows)x\(tensor.columns) mode=\(policy.mode.rawValue)"
        )
        let audit = try auditQuantizedTensor(tensor)
        for matrix in audit.matrices {
            try matrixWriter.write(matrixJSON(audit: audit, matrix: matrix))
        }
        try tensorWriter.write(tensorJSON(audit))
        collector.add(audit)
        aggregate.add(audit)
        progress(
            "TENSOR_END ordinal=\(ordinal + 1)/\(weightLocations.count) "
                + "name=\(base) rank_pass=\(audit.matrices.filter { $0.rank.rulesOut39Percent }.count)"
                + "/\(audit.matrices.count)"
        )
    }

    let (routedLayers, routedModels) = try collector.summarize()
    guard
        routedLayers.filter({ $0.scope == "language_model" }).count == 40,
        routedLayers.filter({ $0.scope == "mtp" }).count == 1
    else {
        throw AuditError.invalid("routed tile summary did not cover 40 main + 1 MTP layers")
    }
    try writeJSON(
        [
            "schema_version": 1,
            "layers": routedLayers.map(routedLayerJSON),
            "models": routedModels.map(routedModelJSON),
        ],
        to: outputURL.appendingPathComponent("routed-tiles.json")
    )

    progress("HASH_BEGIN files=\(index.shards.count + 2)")
    var fileRecords: [[String: Any]] = []
    for url in [configURL, indexURL] + index.shards.map(\.url) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as! NSNumber).int64Value
        let hash = try sha256File(url)
        fileRecords.append(
            [
                "path": url.lastPathComponent,
                "size_bytes": NSNumber(value: size),
                "sha256": hash,
            ]
        )
        progress("HASH_FILE path=\(url.lastPathComponent) sha256=\(hash)")
    }

    try archiveMetadataFile(configURL, as: "model-config.json", under: outputURL)
    try archiveMetadataFile(indexURL, as: "model-index.json", under: outputURL)
    let manifest: [String: Any] = [
        "schema_version": 1,
        "probe": "qwen36-real-weight-structure-audit",
        "date_utc": iso8601Now(),
        "snapshot_path": snapshotURL.path,
        "decode_contract": [
            "affine": "root-pinned-MLX-0a725e30-bfloat16-multiply-then-add",
            "mxfp8": "MLX-E4M3-times-E8M0-to-bfloat16",
        ],
        "rank_contract": [
            "fields": [3, 5],
            "mapping": "exact-dyadic-BF16-field-homomorphism",
            "claim": "deterministic-minor-exact-lower-bound",
            "deletion_threshold": 0.39,
            "required_formula": "floor(0.61*N*K/(N+K))+1",
        ],
        "source_sha256": ProcessInfo.processInfo.environment["AUDIT_SOURCE_SHA256"]
            ?? "not-supplied",
        "root_git_sha": ProcessInfo.processInfo.environment["AUDIT_ROOT_GIT_SHA"]
            ?? "not-supplied",
        "root_pinned_mlx_gitlink":
            ProcessInfo.processInfo.environment["AUDIT_PINNED_MLX_SHA"]
            ?? "not-supplied",
        "files": fileRecords,
        "coverage": [
            "all_u32_tensors_are_weights": true,
            "quantized_weight_tensors": weightLocations.count,
            "expert_tensors": expertTensorCount,
            "dense_tensors": denseTensorCount,
            "logical_expert_matrices": expertMatrixCount,
            "logical_dense_matrices": denseTensorCount,
        ],
        "config": config,
    ]
    try writeJSON(manifest, to: outputURL.appendingPathComponent("manifest.json"))

    let summary = summaryJSON(
        aggregate: aggregate,
        routedModels: routedModels
    )
    try writeJSON(summary, to: outputURL.appendingPathComponent("summary.json"))
    let summaryText = summaryText(
        aggregate: aggregate,
        routedModels: routedModels
    )
    try Data(summaryText.utf8).write(
        to: outputURL.appendingPathComponent("summary.txt"),
        options: .atomic
    )
    print(summaryText, terminator: "")

    guard aggregate.rankFailureCount == 0 else {
        throw AuditError.invalid(
            "\(aggregate.rankFailureCount) matrices lack the required exact rank bound"
        )
    }
}

private func matrixJSON(
    audit: TensorAudit,
    matrix: MatrixAudit
) -> [String: Any] {
    let tensor = audit.tensor
    return [
        "record": "matrix",
        "tensor": tensor.baseName,
        "kind": tensor.isExpertTensor ? "routed_expert" : "dense",
        "matrix_index": matrix.matrixIndex,
        "rows_n": tensor.rows,
        "columns_k": tensor.columns,
        "quantization": [
            "mode": tensor.policy.mode.rawValue,
            "bits": tensor.policy.bits,
            "group_size": tensor.policy.groupSize,
            "decode_contract": tensor.policy.decodeContract,
        ],
        "raw_code_histogram": matrix.codeHistogram.map { NSNumber(value: $0) },
        "decoded": [
            "value_count": NSNumber(value: Int64(tensor.rows * tensor.columns)),
            "zero_count": NSNumber(value: matrix.decodedZeroCount),
            "positive_zero_count": NSNumber(value: matrix.decodedPositiveZeroCount),
            "negative_zero_count": NSNumber(value: matrix.decodedNegativeZeroCount),
            "nonfinite_count": NSNumber(value: matrix.decodedNonFiniteCount),
            "hash128": matrix.decodedHash,
        ],
        "zero_masks": [
            "row_count": matrix.exactZeroRowCount,
            "column_count": matrix.exactZeroColumnCount,
            "rows_base64_lsb0": bitMaskBase64(matrix.zeroRows),
            "columns_base64_lsb0": bitMaskBase64(matrix.zeroColumns),
        ],
        "aligned_zero_structures": [
            "row_segments": intKeyDictionary(matrix.rowSegmentZeroCounts),
            "column_blocks": intKeyDictionary(matrix.columnBlockZeroCounts),
            "blocks": matrix.allZeroBlockCounts.mapValues { NSNumber(value: $0) },
        ],
        "duplicates": [
            "rows": duplicateJSON(matrix.rowDuplicates),
            "columns": duplicateJSON(matrix.columnDuplicates),
            "quantization_groups": duplicateJSON(matrix.groupDuplicates),
            "metadata_rows": duplicateJSON(matrix.metadataRowDuplicates),
        ],
        "metadata_identity": [
            "scale_bias_equal_positions":
                NSNumber(value: matrix.scaleBiasEqualPositions),
            "adjacent_identical_scales":
                NSNumber(value: matrix.adjacentIdenticalScales),
            "adjacent_identical_biases":
                NSNumber(value: matrix.adjacentIdenticalBiases),
            "adjacent_identical_scale_bias_pairs":
                NSNumber(value: matrix.adjacentIdenticalScaleBiasPairs),
            "constant_scale_rows": matrix.constantScaleRows,
            "constant_bias_rows": matrix.constantBiasRows,
            "constant_scale_bias_rows": matrix.constantScaleBiasRows,
        ],
        "rank": rankJSON(matrix.rank),
    ]
}

private func tensorJSON(_ audit: TensorAudit) -> [String: Any] {
    let tensor = audit.tensor
    var object: [String: Any] = [
        "record": "tensor",
        "tensor": tensor.baseName,
        "kind": tensor.isExpertTensor ? "routed_expert_tensor" : "dense_tensor",
        "weight_shape": tensor.weight.location.shape,
        "matrix_count": tensor.matrixCount,
        "matrix_shape": [tensor.rows, tensor.columns],
        "quantization": [
            "mode": tensor.policy.mode.rawValue,
            "bits": tensor.policy.bits,
            "group_size": tensor.policy.groupSize,
            "decode_contract": tensor.policy.decodeContract,
        ],
        "raw_sha256": [
            "weight": audit.weightSHA256,
            "scales": audit.scalesSHA256,
            "biases": jsonOptional(audit.biasesSHA256),
        ],
        "raw_code_histogram": audit.codeHistogram.map { NSNumber(value: $0) },
        "raw_scale_histogram": sparseHistogramJSON(
            audit.scaleHistogram,
            width: tensor.policy.mode == .mxfp8 ? 2 : 4
        ),
        "raw_bias_histogram": sparseHistogramJSON(audit.biasHistogram, width: 4),
    ]
    if let expertDuplicates = audit.expertDuplicates {
        object["whole_expert_duplicates"] = duplicateJSON(expertDuplicates)
    }
    return object
}

private func duplicateJSON(_ stats: DuplicateStats) -> [String: Any] {
    [
        "total_items": stats.totalItems,
        "unique_items": stats.uniqueItems,
        "duplicate_items": stats.duplicateItems,
        "duplicate_classes": stats.duplicateClasses,
        "maximum_multiplicity": stats.maximumMultiplicity,
        "unequal_hash_collisions_exactly_rejected": stats.unequalHashCollisions,
        "class_digest_sha256": stats.classDigestSHA256,
        "class_samples": stats.classSamples.map {
            ["hash": $0.hash, "count": $0.count] as [String: Any]
        },
    ]
}

private func rankJSON(_ rank: RankCertificate) -> [String: Any] {
    [
        "status": rank.status,
        "prime": jsonOptional(rank.prime),
        "exact_lower_bound": rank.exactLowerBound,
        "exact_upper_bound": rank.exactUpperBound,
        "required_to_rule_out_39_percent": rank.requiredToRuleOut39Percent,
        "target": rank.target,
        "rules_out_39_percent": rank.rulesOut39Percent,
        "attempt": jsonOptional(rank.attempt),
        "selected_row_count": rank.selectedRowCount,
        "selected_column_count": rank.selectedColumnCount,
        "minor_row_index_sha256": jsonOptional(rank.minorRowIndexSHA256),
        "minor_column_index_sha256": jsonOptional(rank.minorColumnIndexSHA256),
        "minor_field_values_sha256": jsonOptional(rank.minorFieldValueSHA256),
        "rank_factor_mac_deletion_upper_bound":
            rank.macDeletionUpperBound,
        "claim_limit":
            rank.status == "exact-rank"
            ? "exact rank equals reported lower/upper bound"
            : "exact lower bound only; no full-rank claim",
    ]
}

private func routedLayerJSON(_ layer: RoutedLayerSummary) -> [String: Any] {
    [
        "scope": layer.scope,
        "layer": layer.layer,
        "expert_count": layer.expertCount,
        "gate_zero_rows": layer.gateZeroRows,
        "up_zero_rows": layer.upZeroRows,
        "dead_hidden_channels_gate_or_up": layer.deadHiddenChannels,
        "gate_up_zero_masks_equal": layer.gateUpZeroMasksEqual,
        "gate_up_scale_payloads_equal": layer.gateUpScalePayloadsEqual,
        "gate_up_bias_payloads_equal": layer.gateUpBiasPayloadsEqual,
        "gate_bn32_aligned_zero_tiles": layer.gateBN32AlignedZeroTiles,
        "up_bn32_aligned_zero_tiles": layer.upBN32AlignedZeroTiles,
        "gate_bn32_compaction_tiles_removed":
            layer.gateBN32CompactionTilesRemoved,
        "up_bn32_compaction_tiles_removed":
            layer.upBN32CompactionTilesRemoved,
        "gate_up_bn32_tile_slots": layer.gateUpBN32TileSlots,
        "down_bk8_dead_activation_fragments":
            layer.downBK8DeadActivationFragments,
        "down_bk8_zero_weight_column_fragments":
            layer.downBK8ZeroWeightColumnFragments,
        "down_bk8_fragment_slots": layer.downBK8FragmentSlots,
        "gate_up_macs": NSNumber(value: layer.gateUpMACs),
        "down_macs": NSNumber(value: layer.downMACs),
        "removable_gate_up_macs_bn32_compaction":
            NSNumber(value: layer.removableGateUpMACsByBN32Compaction),
        "removable_down_macs_aligned_bk8_dead_activation":
            NSNumber(value: layer.removableDownMACsByAlignedBK8DeadActivation),
    ]
}

private func routedModelJSON(_ model: RoutedModelSummary) -> [String: Any] {
    [
        "scope": model.scope,
        "layer_count": model.layerCount,
        "expert_instances": model.expertCount,
        "gate_zero_rows": model.gateZeroRows,
        "up_zero_rows": model.upZeroRows,
        "dead_hidden_channels_gate_or_up": model.deadHiddenChannels,
        "unequal_gate_up_zero_mask_layers": model.unequalGateUpZeroMaskLayers,
        "gate_up_bn32_tile_slots": model.gateUpBN32TileSlots,
        "gate_up_bn32_aligned_zero_tiles": model.gateUpBN32AlignedZeroTiles,
        "gate_up_bn32_compaction_tiles_removed":
            model.gateUpBN32CompactionTilesRemoved,
        "down_bk8_fragment_slots": model.downBK8FragmentSlots,
        "down_bk8_dead_activation_fragments":
            model.downBK8DeadActivationFragments,
        "down_bk8_zero_weight_column_fragments":
            model.downBK8ZeroWeightColumnFragments,
        "routed_macs": NSNumber(value: model.routedMACs),
        "removable_macs": NSNumber(value: model.removableMACs),
        "removable_mac_fraction": model.removableMACFraction,
    ]
}

private func summaryJSON(
    aggregate: AggregateSummary,
    routedModels: [RoutedModelSummary]
) -> [String: Any] {
    [
        "schema_version": 1,
        "run_valid": aggregate.rankFailureCount == 0,
        "coverage": [
            "tensor_count": aggregate.tensorCount,
            "expert_tensor_count": aggregate.expertTensorCount,
            "dense_tensor_count": aggregate.denseTensorCount,
            "matrix_count": aggregate.matrixCount,
            "expert_matrix_count": aggregate.expertMatrixCount,
            "dense_matrix_count": aggregate.denseMatrixCount,
        ],
        "rank": [
            "pass_count": aggregate.rankPassCount,
            "failure_count": aggregate.rankFailureCount,
            "exact_rank_count": aggregate.exactRankCount,
            "gf3_certificate_count": aggregate.rankGF3Count,
            "gf5_certificate_count": aggregate.rankGF5Count,
            "maximum_per_matrix_deletion_upper_bound":
                aggregate.maximumPerMatrixRankDeletionUpperBound,
            "mac_weighted_deletion_upper_bound":
                aggregate.baselineMACs == 0
                ? 0
                : aggregate.rankBoundRemovableMACs / aggregate.baselineMACs,
            "threshold_ruled_out": 0.39,
            "claim":
                aggregate.rankFailureCount == 0
                ? "every audited matrix has a deterministic exact finite-field minor above the >=39% rank-factor deletion cutoff"
                : "one or more matrices lack the required exact lower bound",
        ],
        "structure": [
            "decoded_values": NSNumber(value: aggregate.totalDecodedValues),
            "decoded_zeros": NSNumber(value: aggregate.totalDecodedZeros),
            "zero_rows": NSNumber(value: aggregate.totalZeroRows),
            "zero_columns": NSNumber(value: aggregate.totalZeroColumns),
            "duplicate_rows": NSNumber(value: aggregate.totalDuplicateRows),
            "duplicate_columns": NSNumber(value: aggregate.totalDuplicateColumns),
            "duplicate_groups": NSNumber(value: aggregate.totalDuplicateGroups),
            "duplicate_experts": NSNumber(value: aggregate.totalDuplicateExperts),
            "bn32_bk8_block_slots":
                NSNumber(value: aggregate.totalBN32BK8Blocks),
            "zero_bn32_bk8_blocks":
                NSNumber(value: aggregate.totalZeroBN32BK8Blocks),
        ],
        "routed_tiles": routedModels.map(routedModelJSON),
        "limits": [
            "rank": "lower bounds stop at required+64 unless the exact structural upper bound is reached",
            "near_rank": "not measured; approximate SVD cannot establish exact rank and is non-shippable for this objective",
            "routing": "real prompt routing histograms are a separate R4 requirement and are not inferred from weights",
        ],
    ]
}

private func summaryText(
    aggregate: AggregateSummary,
    routedModels: [RoutedModelSummary]
) -> String {
    let weightedRankBound =
        aggregate.baselineMACs == 0
        ? 1
        : aggregate.rankBoundRemovableMACs / aggregate.baselineMACs
    var lines = [
        "PROBE=qwen36-real-weight-structure-audit",
        "RUN_VALID=\(aggregate.rankFailureCount == 0 ? "yes" : "no")",
        "DECODE_AFFINE=root-pinned-MLX-0a725e30-bfloat16-multiply-then-add",
        "COVERAGE tensors=\(aggregate.tensorCount) expert_tensors=\(aggregate.expertTensorCount) dense_tensors=\(aggregate.denseTensorCount) matrices=\(aggregate.matrixCount) expert_matrices=\(aggregate.expertMatrixCount) dense_matrices=\(aggregate.denseMatrixCount)",
        "RANK pass=\(aggregate.rankPassCount) fail=\(aggregate.rankFailureCount) exact=\(aggregate.exactRankCount) gf3=\(aggregate.rankGF3Count) gf5=\(aggregate.rankGF5Count) weighted_deletion_upper=\(formatFraction(weightedRankBound)) max_matrix_deletion_upper=\(formatFraction(aggregate.maximumPerMatrixRankDeletionUpperBound)) threshold=0.390000",
        "STRUCTURE decoded_values=\(aggregate.totalDecodedValues) decoded_zeros=\(aggregate.totalDecodedZeros) zero_rows=\(aggregate.totalZeroRows) zero_columns=\(aggregate.totalZeroColumns) duplicate_rows=\(aggregate.totalDuplicateRows) duplicate_columns=\(aggregate.totalDuplicateColumns) duplicate_groups=\(aggregate.totalDuplicateGroups) duplicate_experts=\(aggregate.totalDuplicateExperts)",
        "GENERIC_TILES bn32_bk8_slots=\(aggregate.totalBN32BK8Blocks) zero_bn32_bk8=\(aggregate.totalZeroBN32BK8Blocks)",
    ]
    for model in routedModels.sorted(by: { $0.scope < $1.scope }) {
        lines.append(
            "ROUTED_TILES scope=\(model.scope) layers=\(model.layerCount) "
                + "bn32_compaction_removed=\(model.gateUpBN32CompactionTilesRemoved)"
                + "/\(model.gateUpBN32TileSlots) "
                + "bn32_aligned_zero=\(model.gateUpBN32AlignedZeroTiles)"
                + "/\(model.gateUpBN32TileSlots) "
                + "bk8_dead_activation=\(model.downBK8DeadActivationFragments)"
                + "/\(model.downBK8FragmentSlots) "
                + "bk8_zero_weight=\(model.downBK8ZeroWeightColumnFragments)"
                + "/\(model.downBK8FragmentSlots) "
                + "removable_routed_mac_fraction=\(formatFraction(model.removableMACFraction))"
        )
    }
    lines.append(
        "VERDICT=\(aggregate.rankFailureCount == 0 ? "rank-factor->=39%-deletion-ruled-out" : "insufficient-rank-certificate") exact_finite_field=true lower_bounds_labelled=true"
    )
    lines.append(
        "LIMITS=rank-stops-at-required-plus-64-unless-exact-upper-reached;near-rank-not-shippable;real-routing-separate"
    )
    return lines.joined(separator: "\n") + "\n"
}

private func sparseHistogramJSON(
    _ histogram: [UInt16: UInt64],
    width: Int
) -> [[Any]] {
    histogram.keys.sorted().map {
        [
            String(format: "0x%0*llx", width, UInt64($0)),
            NSNumber(value: histogram[$0]!),
        ]
    }
}

private func intKeyDictionary<T: BinaryInteger>(
    _ values: [Int: T]
) -> [String: NSNumber] {
    Dictionary(uniqueKeysWithValues: values.map {
        (String($0.key), NSNumber(value: Int64($0.value)))
    })
}

private func bitMaskBase64(_ mask: [Bool]) -> String {
    var bytes = [UInt8](repeating: 0, count: (mask.count + 7) / 8)
    for (index, value) in mask.enumerated() where value {
        bytes[index / 8] |= UInt8(1) << UInt8(index & 7)
    }
    return Data(bytes).base64EncodedString()
}

private func jsonOptional<T>(_ value: T?) -> Any {
    if let value { return value }
    return NSNull()
}

private func writeJSON(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    try (data + Data([0x0a])).write(to: url, options: .atomic)
}

private func archiveMetadataFile(_ source: URL, as name: String, under root: URL) throws {
    let destination = root.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: source, to: destination)
}

private func iso8601Now() -> String {
    ISO8601DateFormatter().string(from: Date())
}

private func formatFraction(_ value: Double) -> String {
    String(format: "%.9f", value)
}

private func runSelfTests() throws {
    try runExactRankSelfTests()
    let scale = floatToBF16RoundToNearestEven(0.0185546875)
    let bias = floatToBF16RoundToNearestEven(-1.9921875)
    let oldContract = bf16ToFloat(
        affineDecodedBF16(code: 15, scale: scale, bias: bias)
    )
    guard oldContract == -1.71875 else {
        throw AuditError.invalid(
            "pinned affine decode self-test failed: \(oldContract)"
        )
    }
    guard
        mxfp8DecodedBF16(code: 0x38, scale: 127)
            == floatToBF16RoundToNearestEven(1),
        mxfp8DecodedBF16(code: 0xb8, scale: 127)
            == floatToBF16RoundToNearestEven(-1),
        rankRequiredToRuleOut39Percent(rows: 512, columns: 2048) == 250,
        rankRequiredToRuleOut39Percent(rows: 2048, columns: 512) == 250
    else {
        throw AuditError.invalid("decode/rank threshold self-test failed")
    }
}

do {
    try main()
} catch {
    FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
    exit(1)
}
