import Foundation

func checkQwenPrefillPhaseCLI() throws {
    let pinned = ["--model-dir", "/registered-model", "--artifact-aggregate-sha256", String(repeating: "a", count: 64),
        "--tokens-file", "/prompt.json", "--long-prompt-sha256", String(repeating: "b", count: 64),
        "--execution-path", "cbv2-contiguous", "--prompt-tokens", "8192", "--chunk-size", "512",
        "--decode-tokens", "1", "--repeats", "1", "--warmups", "0"]
    let phase = ["--prefill-phase-trace-file", "/new-phase-trace.json"]
    let solo = ["--mode", "qwen-long-prefill-solo-check"] + pinned
    let ranks = ["--mode", "qwen-long-prefill-rank-check"] + pinned + ["--transport", "loopback-test",
        "--epoch", String(repeating: "c", count: 32), "--stage-prefill-policy", "serial_v1",
        "--stage-logits-dtype", "bfloat16"]
    for arguments in [solo, ranks] {
        guard try Options(arguments: arguments).prefillPhaseTraceFile == nil,
              try Options(arguments: arguments + phase).prefillPhaseTraceFile?.path == "/new-phase-trace.json" else {
            throw ProbeError("Optional phase CLI changed its disabled or explicit path")
        }
    }
    let refused = [["--mode", "adapter-check"], ["--mode", "capability"],
        ["--mode", "qwen-long-prefill-reference"] + pinned,
        ["--mode", "qwen-long-prefill-pair-check"] + pinned,
        ["--mode", "baseline", "--synthetic"]]
    for arguments in refused {
        do {
            _ = try Options(arguments: arguments + phase)
        } catch { continue }
        throw ProbeError("Unrelated native mode accepted a prefill phase trace")
    }
    struct Record: Encodable {
        let kind = "qwen_prefill_phase_cli_check", cpuOnly = true
        let acceptedCases = 4, rejectedCases = 5
    }
    try emitJSON(Record())
}
