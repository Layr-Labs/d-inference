import Foundation
import MLX

/// Root-only native self-check: the public short comparison path receives a new
/// saved tiny12 artifact, explicit cut4, and the fixed 65/32/4 recorded timeline.
/// Historical tiny8 fixtures and production synthetic profile admission stay intact.
func checkQwenLayerStageUnequalCutRecording(options: Options, check: () throws -> Void) throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("qwen-stage-cut-recording-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let directory = workspace.appendingPathComponent("checkpoint")
    let source = try autoreleasepool { () throws -> (aggregate: String, names: Set<String>, configuration: Data) in
        var fixtureOptions = options; fixtureOptions.syntheticDType = "bfloat16"
        let model = try makeQwenLayerStageSyntheticModel(options: fixtureOptions, wrapped: true,
            layerCount: 12, check: check)
        guard model.layerCount == 12, model.label.contains("12x4"),
              let root = try JSONSerialization.jsonObject(with: model.configurationData) as? [String: Any],
              let text = root["text_config"] as? [String: Any],
              text["cluster_fixture_profile"] as? String == "tiny-layer-stage-12x4" else {
            throw ProbeError("Unequal-cut fixture did not retain its distinct explicit tiny12 identity")
        }
        let fixture = try writeLoaderFixture(model, directory: directory, fp16FFNMetadata: true)
        try check()
        guard fixture.fp16MetadataTensorCount > 0,
              fixture.sourceTensorCount == fixture.parameters.count,
              fixture.sourcePartsPerTensor.values.allSatisfy({ $0 == 1 }) else {
            throw ProbeError("Unequal-cut fixture lost complete canonical source or F16 metadata coverage")
        }
        return (fixture.aggregateSHA256, Set(fixture.parameters.keys), model.configurationData)
    }
    Memory.clearCache(); try check()
    let promptFile = workspace.appendingPathComponent("prompt.json")
    let teacherFile = workspace.appendingPathComponent("teacher.json")
    try JSONEncoder().encode((0..<65).map { 3 + (($0 * 17 + 7) % 509) }).write(to: promptFile)
    try JSONEncoder().encode([12, 25, 38]).write(to: teacherFile)
    let compared = try Options(arguments: ["--mode", "qwen-layer-stage-compare", "--model-dir", directory.path,
        "--artifact-aggregate-sha256", source.aggregate, "--stage-cut", "4",
        "--tokens-file", promptFile.path, "--teacher-tokens-file", teacherFile.path,
        "--execution-path", "cbv2-contiguous", "--prompt-tokens", "65", "--chunk-size", "32",
        "--decode-tokens", "4", "--repeats", "1", "--warmups", "0", "--timeout-seconds", "180"])
    let inputs = try QwenLayerStageComparisonAdmission.preflight(compared)
    guard inputs.configurationData == source.configuration,
          inputs.plan.stages.map(\.sourceRange) == [0..<4, 4..<12] else {
        throw ProbeError("Short comparison did not retain the explicit unequal tiny12 plan")
    }
    let result = try runQwenLayerStageComparison(options: compared, inputs: inputs, check: check)
    let loads = result.stageLoads, frames = result.comparison.frames
    guard loads.count == 2, loads.map(\.stageIndex) == [0, 1],
          loads.map(\.stagePlanSHA256) == inputs.plan.stages.map(\.fingerprint),
          loads.map(\.constructionConfigurationSHA256) == inputs.plan.stages.map({ sha256($0.constructionConfiguration) }),
          loads.allSatisfy({ $0.planSHA256 == inputs.plan.fingerprint && $0.bf16ConversionEnabled }),
          loads[0].storageCommitmentSHA256 == loads[1].storageCommitmentSHA256,
          loads.flatMap(\.activeTensors).count == source.names.count,
          Set(loads.flatMap(\.activeTensors).map(\.sourceName)) == source.names,
          frames.map(\.committedTokens) == [32, 64, 65, 66, 67, 68],
          frames.allSatisfy({ $0.stateEntriesCompared == 27 && $0.stateMetadataAndDigestsExact }),
          frames.filter({ $0.logits != nil }).count == 4,
          frames.filter({ $0.nativeLogitBytesExact == true }).count == 4,
          result.comparison.allRequestStateRetired,
          result.baselineModelReleasedBeforeStageLoading, result.stageModelsReleasedAfterComparison else {
        throw ProbeError("Unequal-cut fixture lost source ownership, exact state/logits or model/request retirement")
    }
    struct Result: Encodable {
        let kind = "qwen_layer_stage_unequal_cut_recording_check"
        let fixtureProfile = "tiny-layer-stage-12x4", selectedCut = 4
        let layerCounts = [4, 8], correctnessOnly = true, throughputMeasurementValid = false
        let comparison: QwenLayerStageComparisonReport
    }
    try emitJSON(Result(comparison: result))
}
