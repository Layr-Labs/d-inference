import Foundation

func checkQwenLayerStageComparisonAdmission() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stage-real-input-check-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configFile = directory.appendingPathComponent("config.json")
    let promptFile = directory.appendingPathComponent("prompt.json")
    let teacherFile = directory.appendingPathComponent("teacher.json")
    let basic = ["--mode", "qwen-layer-stage-compare", "--model-dir", directory.path,
        "--artifact-aggregate-sha256", String(repeating: "a", count: 64),
        "--tokens-file", promptFile.path, "--teacher-tokens-file", teacherFile.path,
        "--execution-path", "cbv2-contiguous", "--prompt-tokens", "65", "--chunk-size", "32",
        "--decode-tokens", "4", "--repeats", "1", "--warmups", "0", "--timeout-seconds", "170"]
    let options = try Options(arguments: basic)
    let config = try syntheticConfiguration(options: options)
    let prompt = (0..<65).map { 3 + (($0 * 17 + 7) % 509) }, teacher = [12, 25, 38]
    try config.write(to: configFile)
    try JSONEncoder().encode(prompt).write(to: promptFile)
    try JSONEncoder().encode(teacher).write(to: teacherFile)
    let input = try QwenLayerStageComparisonAdmission.preflight(options)
    try Data("[]".utf8).write(to: promptFile)
    try Data("[]".utf8).write(to: teacherFile)
    try Data("{}".utf8).write(to: configFile)
    guard input.prompt == prompt, input.teacher == teacher, input.configurationData == config,
        input.plan.stages.map(\.sourceRange) == [0..<2, 2..<4], input.conservativeStateAndBoundaryBytes > 0 else {
        throw ProbeError("Real stage preflight failed to retain exact inputs and aligned plan")
    }
    var rejected = 0
    func reject(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { rejected += 1; return }
        throw ProbeError("Real stage comparison admitted " + label)
    }
    for (flag, value) in [("--prompt-tokens", "129"), ("--chunk-size", "33"),
        ("--decode-tokens", "5"), ("--repeats", "2"), ("--warmups", "1"),
        ("--timeout-seconds", "181"), ("--execution-path", "ordinary"),
        ("--artifact-aggregate-sha256", "invalid")] {
        var args = basic; args[args.firstIndex(of: flag)! + 1] = value
        try reject(flag) { _ = try Options(arguments: args) }
    }
    for flag in ["--artifact-aggregate-sha256", "--tokens-file", "--teacher-tokens-file"] {
        var args = basic; let index = args.firstIndex(of: flag)!; args.removeSubrange(index...index + 1)
        try reject("missing " + flag) { _ = try Options(arguments: args) }
    }
    for extra in [["--synthetic"], ["--local-correctness"], ["--transport", "loopback-test"],
        ["--partition", "full"], ["--logits-file", "unused"], ["--seed", "8"],
        ["--attention-output-precision", "float32"], ["--ffn-output-precision", "float32"],
        ["--ffn-branch-precision", "float32"], ["--routing-file", "unused"],
        ["--gemma-diagnostic"], ["--epoch", String(repeating: "a", count: 32)]] {
        try reject("incompatible option") { _ = try Options(arguments: basic + extra) }
    }
    try config.write(to: configFile)
    try JSONEncoder().encode(teacher).write(to: teacherFile)
    for raw in ["[true]", "[1.0]", "[]", "[1]", "[512]", "[-1]"] {
        try Data(raw.utf8).write(to: promptFile)
        try reject("token syntax/count/range") { _ = try QwenLayerStageComparisonAdmission.preflight(options) }
    }
    try JSONEncoder().encode(prompt).write(to: promptFile)
    try JSONEncoder().encode([12, 25]).write(to: teacherFile)
    try reject("short teacher") { _ = try QwenLayerStageComparisonAdmission.preflight(options) }
    try JSONEncoder().encode(teacher).write(to: teacherFile)
    let root = try JSONSerialization.jsonObject(with: config) as! [String: Any]
    for (key, value) in [("num_hidden_layers", 6), ("max_position_embeddings", 68)] {
        var changed = root; changed[key] = value
        try JSONSerialization.data(withJSONObject: changed).write(to: configFile)
        try reject("phase/context") { _ = try QwenLayerStageComparisonAdmission.preflight(options) }
    }
    var large = root
    for (key, value) in [("num_hidden_layers", 128), ("linear_num_key_heads", 128),
        ("linear_num_value_heads", 128), ("linear_key_head_dim", 512), ("linear_value_head_dim", 512)] {
        large[key] = value
    }
    try JSONSerialization.data(withJSONObject: large).write(to: configFile)
    try reject("state estimate above 512 MiB") { _ = try QwenLayerStageComparisonAdmission.preflight(options) }
    struct Result: Encodable {
        let kind = "qwen_layer_stage_comparison_admission_check"
        let cpuOnly = true
        let retainedPromptTeacherAndConfiguration = true
        let rejectedFixtures: Int
    }
    try emitJSON(Result(rejectedFixtures: rejected))
}
