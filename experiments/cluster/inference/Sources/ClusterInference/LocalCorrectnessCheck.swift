import Foundation

/// Exercises CLI admission and actual-file preflight without initializing MLX.
func checkLocalCorrectness() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cluster-local-correctness-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configFile = directory.appendingPathComponent("config.json")
    let promptFile = directory.appendingPathComponent("prompt.json")
    let teacherFile = directory.appendingPathComponent("teacher.json")
    let config: [String: Any] = ["model_type": "qwen3_5", "text_config": [
        "vocab_size": 248320, "max_position_embeddings": 262144, "num_experts": 0]]
    let configuration = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
    try configuration.write(to: configFile)
    try JSONEncoder().encode([1, 2, 3]).write(to: promptFile)
    try JSONEncoder().encode([4, 5, 6]).write(to: teacherFile)
    let arguments = ["--mode", "ffn-tp", "--model-dir", directory.path,
        "--transport", "loopback-test", "--local-correctness",
        "--artifact-aggregate-sha256", String(repeating: "a", count: 64),
        "--prompt-tokens", "3", "--chunk-size", "2", "--decode-tokens", "4",
        "--repeats", "1", "--warmups", "0", "--timeout-seconds", "30",
        "--tokens-file", promptFile.path, "--teacher-tokens-file", teacherFile.path,
        "--logits-file", directory.appendingPathComponent("logits.json").path]
    func changed(_ flag: String, _ value: String?) -> [String] {
        var result = arguments
        let index = result.firstIndex(of: flag)!
        if let value { result[index + 1] = value }
        else { result.removeSubrange(index...index + 1) }
        return result
    }
    var rejected = 0
    func reject(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { rejected += 1; return }
        throw ProbeError("Local correctness accepted invalid " + label)
    }
    let options = try Options(arguments: arguments)
    guard let inputs = try LocalCorrectness.preflight(options),
        inputs.prompt == [1, 2, 3], inputs.teacher == [4, 5, 6],
        inputs.configurationSHA256 == sha256(configuration) else {
        throw ProbeError("Local correctness preflight changed admitted inputs")
    }
    // Changing files after admission cannot replace the retained token history.
    try JSONEncoder().encode([7, 8, 9]).write(to: promptFile)
    guard inputs.prompt == [1, 2, 3] else { throw ProbeError("Preflight did not retain prompt IDs") }
    let invalidOptions: [(String, String?)] = [
        ("--mode", "baseline"), ("--mode", "worker-tp"), ("--transport", "jaccl"),
        ("--prompt-tokens", "129"), ("--chunk-size", "33"), ("--decode-tokens", "5"),
        ("--repeats", "2"), ("--warmups", "1"), ("--timeout-seconds", "181"),
        ("--tokens-file", nil), ("--teacher-tokens-file", nil), ("--logits-file", nil),
        ("--artifact-aggregate-sha256", nil), ("--artifact-aggregate-sha256", String(repeating: "A", count: 64)),
    ]
    for (flag, value) in invalidOptions {
        try reject(flag) { _ = try Options(arguments: changed(flag, value)) }
    }
    try reject("unrequested aggregate") {
        _ = try Options(arguments: ["--mode", "baseline", "--synthetic",
            "--artifact-aggregate-sha256", String(repeating: "a", count: 64)])
    }
    try reject("real loopback without opt-in") {
        _ = try Options(arguments: ["--mode", "ffn-tp", "--model-dir", directory.path,
            "--transport", "loopback-test"])
    }
    for tokens in [[1], [Int](repeating: 1, count: 129), [-1, 2, 3], [248320, 2, 3]] {
        try JSONEncoder().encode(tokens).write(to: promptFile)
        try reject("actual prompt") { _ = try LocalCorrectness.preflight(options) }
    }
    try Data(repeating: 32, count: 65_537).write(to: promptFile)
    try reject("oversized token file") { _ = try LocalCorrectness.preflight(options) }
    try JSONEncoder().encode([1, 2, 3]).write(to: promptFile)
    try JSONEncoder().encode([4]).write(to: teacherFile)
    try reject("actual teacher count") { _ = try LocalCorrectness.preflight(options) }
    try JSONEncoder().encode([4, 5, 6]).write(to: teacherFile)
    for lexical in ["[1.0,2,3]", "[1e0,2,3]", "[true,2,3]", "[\"1\",2,3]"] {
        try Data(lexical.utf8).write(to: promptFile)
        try reject("noninteger token syntax") { _ = try LocalCorrectness.preflight(options) }
    }
    try JSONEncoder().encode([1, 2, 3]).write(to: promptFile)
    let invalidConfigs: [[String: Any]] = [
        ["model_type": "gemma4", "vocab_size": 512, "max_position_embeddings": 8192],
        ["model_type": "qwen3_5_moe", "vocab_size": 512, "max_position_embeddings": 8192],
        ["model_type": "qwen3_5_text", "vocab_size": 512, "max_position_embeddings": 8192, "num_experts": 16],
        ["model_type": "qwen3_5_text", "vocab_size": 262145, "max_position_embeddings": 8192],
        ["model_type": "qwen3_5_text", "vocab_size": 512, "max_position_embeddings": 6],
    ]
    for invalid in invalidConfigs {
        try JSONSerialization.data(withJSONObject: invalid).write(to: configFile)
        try reject("actual model/capture/context") { _ = try LocalCorrectness.preflight(options) }
    }
    for field in ["num_experts", "vocab_size", "max_position_embeddings"] {
        for invalid in [false, "0", NSNull(), [Int]()] as [Any] {
            var text: [String: Any] = ["model_type": "qwen3_5_text", "vocab_size": 512,
                                     "max_position_embeddings": 8192, "num_experts": 0]
            text[field] = invalid
            try JSONSerialization.data(withJSONObject: text).write(to: configFile)
            try reject("malformed integer metadata") { _ = try LocalCorrectness.preflight(options) }
        }
    }
    for invalid in [[Int](), NSNull(), "not-an-object"] as [Any] {
        var malformed = config
        malformed["text_config"] = invalid
        // Valid root geometry must not hide the malformed present nested value.
        malformed["vocab_size"] = 512; malformed["max_position_embeddings"] = 8192
        try JSONSerialization.data(withJSONObject: malformed).write(to: configFile)
        try reject("malformed nested config") { _ = try LocalCorrectness.preflight(options) }
    }
    try reject("config hash mismatch") {
        try LocalCorrectness.validateConfiguration(Data("{}".utf8), options: options, inputs: inputs)
    }
    struct Result: Encodable {
        let kind = "local_correctness_admission_check"
        let cpuOnly = true
        let retainedPromptAndTeacher = true
        let rejectedFixtures: Int
    }
    try emitJSON(Result(rejectedFixtures: rejected))
}
