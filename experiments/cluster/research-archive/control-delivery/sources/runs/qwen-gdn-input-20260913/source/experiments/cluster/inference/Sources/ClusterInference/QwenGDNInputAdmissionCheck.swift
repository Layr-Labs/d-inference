import Foundation

/// Byte/count/metadata rejection and retained input checks without MLX execution.
func checkQwenGDNInputAdmission() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gdn-input-check-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let tokens = directory.appendingPathComponent("tokens.json")
    let configuration = directory.appendingPathComponent("config.json")
    let basic = ["--mode", "qwen-gdn-input-check", "--synthetic", "--execution-path", "cbv2-contiguous",
        "--prompt-tokens", "3", "--chunk-size", "3", "--decode-tokens", "1",
        "--repeats", "1", "--warmups", "0", "--timeout-seconds", "30"]
    let synthetic = try Options(arguments: basic)
    let generated = try QwenGDNInputAdmission.preflight(synthetic)
    guard generated.prompt.count == 3 else { throw ProbeError("GDN generated prompt differs") }
    let real = basic.filter { $0 != "--synthetic" } + ["--model-dir", directory.path,
        "--artifact-aggregate-sha256", String(repeating: "a", count: 64), "--tokens-file", tokens.path]
    try generated.configurationData.write(to: configuration)
    try JSONEncoder().encode([1, 2, 3]).write(to: tokens)
    let options = try Options(arguments: real)
    let admitted = try QwenGDNInputAdmission.preflight(options)
    try JSONEncoder().encode([4, 5, 6]).write(to: tokens)
    guard admitted.prompt == [1, 2, 3], admitted.configurationData == generated.configurationData else {
        throw ProbeError("GDN preflight failed to retain exact input")
    }
    var rejected = 0
    func reject(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { rejected += 1; return }
        throw ProbeError("GDN diagnostic accepted " + label)
    }
    for (flag, value) in [("--prompt-tokens", "33"), ("--chunk-size", "2"), ("--decode-tokens", "2"),
        ("--repeats", "2"), ("--warmups", "1"), ("--timeout-seconds", "181"),
        ("--execution-path", "ordinary"), ("--mode", "baseline")] {
        var args = real; args[args.firstIndex(of: flag)! + 1] = value
        try reject(flag) { _ = try Options(arguments: args) }
    }
    for extra in [["--local-correctness"], ["--transport", "loopback-test"], ["--partition", "full"],
        ["--logits-file", "unused"], ["--teacher-tokens-file", "unused"], ["--gemma-diagnostic"],
        ["--attention-output-precision", "float32"], ["--ffn-output-precision", "float32"],
        ["--ffn-branch-precision", "float32"], ["--epoch", String(repeating: "a", count: 32)]] {
        try reject("incompatible option") { _ = try Options(arguments: real + extra) }
    }
    for flag in ["--artifact-aggregate-sha256", "--tokens-file"] {
        var args = real; let index = args.firstIndex(of: flag)!; args.removeSubrange(index...index + 1)
        try reject("missing real input") { _ = try Options(arguments: args) }
    }
    try reject("synthetic pin") { _ = try Options(arguments: basic + ["--artifact-aggregate-sha256", String(repeating: "a", count: 64)]) }
    for content in ["[1.0,2,3]", "[1e0,2,3]", "[true,2,3]", "[\"1\",2,3]", "[]", "[1]", "[-1,2,3]", "[512,2,3]"] {
        try Data(content.utf8).write(to: tokens)
        try reject("actual token syntax/count/range") { _ = try QwenGDNInputAdmission.preflight(options) }
    }
    try Data(repeating: 32, count: 65_537).write(to: tokens)
    try reject("oversized token file") { _ = try QwenGDNInputAdmission.preflight(options) }
    try JSONEncoder().encode([1, 2, 3]).write(to: tokens)
    let valid = try JSONSerialization.jsonObject(with: generated.configurationData) as! [String: Any]
    let invalid: [(String, Any)] = [("model_type", "qwen3_5_moe_text"), ("text_config", [Int]()),
        ("num_experts", 2), ("num_experts", false), ("hidden_size", 16384),
        ("num_hidden_layers", 129), ("linear_num_value_heads", 129), ("vocab_size", 262145),
        ("full_attention_interval", 1), ("max_position_embeddings", 3), ("head_dim", NSNull()),
        ("intermediate_size", "256"), ("linear_key_head_dim", true)]
    for (key, value) in invalid {
        var altered = valid; altered[key] = value
        try JSONSerialization.data(withJSONObject: altered).write(to: configuration)
        try reject("invalid metadata " + key) { _ = try QwenGDNInputAdmission.preflight(options) }
    }
    try Data(repeating: 32, count: 1_048_577).write(to: configuration)
    try reject("oversized config") { _ = try QwenGDNInputAdmission.preflight(options) }
    struct Result: Encodable {
        let kind = "qwen_gdn_input_admission_check"
        let cpuOnly = true
        let retainedInput = true
        let rejectedFixtures: Int
    }
    try emitJSON(Result(rejectedFixtures: rejected))
}
