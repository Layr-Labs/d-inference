import Foundation
import MLX

/// Small saved BF16/F16-metadata artifact exercises the exact recording,
/// model-release and sequential comparison coordinator before a real load.
func checkQwenLayerStageRecordingWithFixture(options: Options, check: () throws -> Void) throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("qwen-stage-recording-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let directory = workspace.appendingPathComponent("checkpoint")
    let aggregate = try autoreleasepool {
        var fixtureOptions = options; fixtureOptions.syntheticDType = "bfloat16"
        let model = try makeQwenLayerStageSyntheticModel(options: fixtureOptions, wrapped: true, check: check)
        let fixture = try writeLoaderFixture(model, directory: directory, fp16FFNMetadata: true)
        try check()
        return fixture.aggregateSHA256
    }
    Memory.clearCache(); try check()
    var compared = options
    compared.mode = .qwenLayerStageCompare; compared.synthetic = false
    compared.modelDirectory = directory; compared.expectedArtifactAggregateSHA256 = aggregate
    compared.tokensFile = workspace.appendingPathComponent("prompt.json")
    let prompt = try promptTokens(options: options, vocabularySize: 512)
    try JSONEncoder().encode(prompt).write(to: compared.tokensFile!)
    if options.decodeCount > 1 {
        compared.teacherTokensFile = workspace.appendingPathComponent("teacher.json")
        let teacher = (0..<(options.decodeCount - 1)).map { 3 + (($0 * 13 + 9) % 509) }
        try JSONEncoder().encode(teacher).write(to: compared.teacherTokensFile!)
    }
    let inputs = try QwenLayerStageComparisonAdmission.preflight(compared)
    try emitJSON(runQwenLayerStageComparison(options: compared, inputs: inputs, check: check))
}
