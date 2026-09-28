import Foundation

func checkQwenLongPrefillReferenceCLI() throws {
    let basic = ["--mode", "qwen-long-prefill-reference", "--model-dir", "unused",
        "--artifact-aggregate-sha256", String(repeating: "a", count: 64),
        "--tokens-file", "unused", "--long-prompt-sha256", String(repeating: "b", count: 64),
        "--execution-path", "cbv2-contiguous", "--prompt-tokens", "8192", "--chunk-size", "512",
        "--decode-tokens", "1", "--repeats", "1", "--warmups", "0", "--timeout-seconds", "300"]
    _ = try Options(arguments: basic)
    var rejected = 0
    func reject(_ args: [String]) throws {
        do { _ = try Options(arguments: args) } catch { rejected += 1; return }
        throw ProbeError("Long reference CLI accepted changed workload or unpinned input")
    }
    for extra in [["--prompt-tokens", "65"], ["--chunk-size", "32"], ["--decode-tokens", "2"],
        ["--repeats", "2"], ["--warmups", "1"], ["--timeout-seconds", "301"], ["--seed", "8"],
        ["--long-prompt-sha256", "bad"], ["--artifact-aggregate-sha256", "bad"],
        ["--synthetic"], ["--execution-path", "ordinary"], ["--teacher-tokens-file", "unused"],
        ["--logits-file", "unused"], ["--local-correctness"], ["--transport", "loopback-test"],
        ["--stage-prefill-policy", "serial_v1"], ["--solo-reference-file", "unused"],
        ["--attention-output-precision", "float32"], ["--mode", "baseline"],
        ["--mode", "qwen-layer-stage-prefill-check"], ["--epoch", String(repeating: "a", count: 32)]] {
        try reject(basic + extra)
    }
    for flag in ["--tokens-file", "--long-prompt-sha256", "--artifact-aggregate-sha256"] {
        var missing = basic; let index = missing.firstIndex(of: flag)!
        missing.removeSubrange(index...(index + 1)); try reject(missing)
    }
    struct Record: Encodable {
        let kind = "qwen_long_prefill_reference_cli_admission", cpuOnly = true
        let acceptedFixtures = 1
        let rejectedFixtures: Int
    }
    try emitJSON(Record(rejectedFixtures: rejected))
}
