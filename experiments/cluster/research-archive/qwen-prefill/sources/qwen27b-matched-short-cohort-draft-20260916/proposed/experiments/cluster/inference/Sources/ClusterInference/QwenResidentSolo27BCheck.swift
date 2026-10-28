import Foundation
@_spi(ClusterBenchmark) import MLXLLM

/// Uses retained config/manifest bytes only; no model, kernel or tensor payload.
func checkQwenResidentSolo27B(root: [String: Any]) throws -> (accepted: Int, rejected: Int) {
    guard let row = root["twentySeven"] as? [String: Any],
          let configText = row["configuration"] as? String, let config = Data(base64Encoded: configText),
          let manifestText = row["manifest"] as? String, let manifest = Data(base64Encoded: manifestText) else {
        throw ProbeError("Solo retained 27B metadata is absent")
    }
    let prompt = try JSONEncoder().encode(Array(repeating: 17, count: 8192))
    let expected = try JSONEncoder().encode(Array(repeating: 19, count: 128))
    let ids = (11...14).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
    let arguments = ["--mode", QwenResidentSoloCLI.mode,
        "--model-dir", "/invented/model", "--tokens-file", "/invented/prompt.json", "--tokens-sha256", sha256(prompt),
        "--request-id", ids[0].uuidString.lowercased(), "--stage-cut", "16", "--output-count", "128",
        "--stop-token-ids", "[]", "--timeout-seconds", "300",
        "--registered-dense-profile", "registered_qwen38_27b", "--prompt-count", "8192", "--chunk-size", "512",
        "--expected-token-ids-file", "/invented/expected.json", "--expected-token-ids-sha256", sha256(expected)]
    var accepted = 0, rejected = 0
    func require(_ value: Bool, _ message: String) throws {
        guard value else { throw ProbeError("Solo 27B CPU check: \(message)") }; accepted += 1
    }
    func refuse(_ body: () throws -> Void) throws {
        do { try body() } catch { rejected += 1; return }
        throw ProbeError("Solo 27B CPU check accepted an invalid case")
    }
    func read(_ url: URL, _: Int) throws -> Data {
        switch url.path {
        case "/invented/model/config.json": return config
        case "/invented/model/manifest.json": return manifest
        case "/invented/prompt.json": return prompt
        case "/invented/expected.json": return expected
        default: throw ProbeError("Unexpected fabricated solo 27B read")
        }
    }
    let cli = try QwenResidentSoloCLI(arguments: arguments)
    var index = 1
    let input = try cli.preflight(environment: QwenLongPrefillArithmeticEnvironment.requiredValues,
        read: read, makeUUID: { defer { index += 1 }; return ids[index] })
    try require(input.requests.map { $0.request.requestID } == ids, "four fresh registered requests")
    try require(input.requests.allSatisfy {
        $0.source.specification.model == .qwen38TwentySevenB && $0.request.forwardCount == 143
            && $0.request.finalCommittedTokens == 8319 && $0.request.maximumTokens == 8320
            && $0.source.plan.stages.map(\.sourceRange) == [0..<16, 16..<64]
    }, "complete 27B trunk and matched request geometry")
    let short = try QwenResidentSoloCLI(arguments: arguments + ["--measured-count", "1"])
    var shortIndex = 1
    let shortInput = try short.preflight(environment: QwenLongPrefillArithmeticEnvironment.requiredValues,
        read: read, makeUUID: { defer { shortIndex += 1 }; return ids[shortIndex] })
    try require(shortInput.requests.map { $0.request.requestID } == Array(ids.prefix(2))
        && shortInput.measuredCount == 1, "explicit one warmup plus one measured request")
    try require(shortIndex == 2, "two-request preflight creates only one additional history")
    try require(cli.measuredCount == 3 && input.measuredCount == 3, "legacy default remains one plus three")
    for bad in ["0", "4", "01", "1.0", "-1"] {
        try refuse { _ = try QwenResidentSoloCLI(arguments: arguments + ["--measured-count", bad]) }
    }
    try refuse { _ = try QwenResidentSoloCLI(arguments: arguments + ["--measured-count", "1", "--measured-count", "1"]) }
    try refuse { _ = try QwenResidentSoloPreflight(first: input.first, requests: input.requests,
        expectedTokenIDs: input.expectedTokenIDs, expectedTokenFileSHA256: input.expectedTokenFileSHA256, measuredCount: 1) }
    let scope = try QwenResidentSoloModelScope(definition: cli.reference.definition)
    try require(scope.gatedDeltaLayers == 48 && scope.warmupProfile.valueHeads == 48,
        "48 actual GDN layers with 48 value heads")
    try scope.requireWarmup(gatedDeltaLayers: 48, fusedLayers: 48, queryBlock: 128,
        nativePrefillCalls: 768, nativeDecodeCalls: 6096, fallbackCalls: 0, invalidGeometryCalls: 0)
    accepted += 1
    for counts in [[24,24,128,384,3048,0,0], [48,47,128,768,6096,0,0],
                   [48,48,64,768,6096,0,0], [48,48,128,767,6096,0,0],
                   [48,48,128,768,6095,0,0], [48,48,128,768,6096,1,0],
                   [48,48,128,768,6096,0,1]] {
        try refuse { try scope.requireWarmup(gatedDeltaLayers: counts[0], fusedLayers: counts[1],
            queryBlock: counts[2], nativePrefillCalls: counts[3], nativeDecodeCalls: counts[4],
            fallbackCalls: counts[5], invalidGeometryCalls: counts[6]) }
    }
    for cut in ["4", "32"] {
        var wrong = arguments; wrong[wrong.firstIndex(of: "--stage-cut")! + 1] = cut
        try refuse { _ = try QwenResidentSoloCLI(arguments: wrong) }
    }
    try refuse { _ = try cli.preflight(environment: QwenLongPrefillArithmeticEnvironment.requiredValues,
        read: read, makeUUID: { ids[0] }) }
    try refuse { _ = try cli.preflight(environment: QwenLongPrefillArithmeticEnvironment.requiredValues,
        read: { url, cap in url.lastPathComponent == "config.json" ? Data("{}".utf8) : try read(url, cap) }) }
    return (accepted, rejected)
}
