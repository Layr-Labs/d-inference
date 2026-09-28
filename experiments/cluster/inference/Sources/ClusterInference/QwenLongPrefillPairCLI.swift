import Foundation

/// The identical registered workload/source/input admission is shared with the
/// reference command. Pair execution has its own explicit mode and output.
enum QwenLongPrefillPairCLI {
    static func referenceOptions(_ options: Options) throws -> Options {
        guard options.mode == .qwenLongPrefillPairCheck else {
            throw ProbeError("Long pair admission requires its explicit diagnostic mode")
        }
        var reference = options
        reference.mode = .qwenLongPrefillReference
        try QwenLongPrefillReferenceCLI.validateOptions(reference)
        return reference
    }

    static func preflight(_ options: Options,
        arithmetic: QwenLongPrefillArithmeticEnvironment.Receipt
    ) throws -> QwenRegistered9BLongPrefillReferenceAdmission {
        try QwenLongPrefillReferenceCLI.preflight(referenceOptions(options), arithmetic: arithmetic)
    }
}

func checkQwenLongPrefillPairCLI() throws {
    let args = ["--mode", "qwen-long-prefill-pair-check", "--model-dir", "unused",
        "--artifact-aggregate-sha256", String(repeating: "a", count: 64),
        "--tokens-file", "unused", "--long-prompt-sha256", String(repeating: "b", count: 64),
        "--execution-path", "cbv2-contiguous", "--prompt-tokens", "8192", "--chunk-size", "512",
        "--decode-tokens", "1", "--repeats", "1", "--warmups", "0", "--timeout-seconds", "300"]
    _ = try QwenLongPrefillPairCLI.referenceOptions(Options(arguments: args))
    let rejected = [["--prompt-tokens", "65"], ["--chunk-size", "32"], ["--decode-tokens", "2"],
        ["--warmups", "1"], ["--repeats", "2"], ["--timeout-seconds", "301"],
        ["--long-prompt-sha256", "bad"], ["--execution-path", "ordinary"],
        ["--teacher-tokens-file", "unused"], ["--transport", "loopback-test"],
        ["--solo-reference-file", "unused"], ["--stage-prefill-policy", "serial_v1"]]
    for extra in rejected {
        do { _ = try Options(arguments: args + extra) } catch { continue }
        throw ProbeError("Long pair accepted a different workload or incompatible diagnostic")
    }
    struct Record: Encodable {
        let kind = "qwen_long_prefill_pair_cli_admission", cpuOnly = true
        let acceptedFixtures = 1
        let rejectedFixtures: Int
    }
    try emitJSON(Record(rejectedFixtures: rejected.count))
}
