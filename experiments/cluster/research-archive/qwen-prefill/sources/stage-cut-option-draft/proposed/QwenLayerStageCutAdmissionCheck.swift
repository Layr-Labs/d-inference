import Foundation

/// Pure CLI/configuration checks. No model construction, payload IO or forward.
func checkQwenLayerStageCutAdmission() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stage-cut-check-" + UUID().uuidString)
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
    let omitted = try Options(arguments: basic)
    let selected = try Options(arguments: basic + ["--stage-cut", "12"])
    var text = try JSONSerialization.jsonObject(with: syntheticConfiguration(options: omitted)) as! [String: Any]
    text["num_hidden_layers"] = 32; text["full_attention_interval"] = 4
    text["layer_types"] = (0..<32).map { ($0 + 1) % 4 == 0 ? "full_attention" : "linear_attention" }
    let configuration = try JSONSerialization.data(withJSONObject: text, options: [.sortedKeys])
    let prompt = (0..<65).map { 3 + (($0 * 17 + 7) % 509) }, teacher = [12, 25, 38]
    try configuration.write(to: configFile)
    try JSONEncoder().encode(prompt).write(to: promptFile)
    try JSONEncoder().encode(teacher).write(to: teacherFile)
    let original = try QwenLayerStageComparisonAdmission.preflight(omitted)
    let equal = try QwenLayerStageComparisonAdmission.preflight(Options(arguments: basic + ["--stage-cut", "16"]))
    let unequal = try QwenLayerStageComparisonAdmission.preflight(selected)
    let expected = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<12, 12..<32])
    let componentCounts = unequal.plan.stages.map { stage in
        stage.layers.reduce(0) { $0 + ($1.kind == "full_attention" ? 3 : 2) }
    }
    guard omitted.stageCut == nil, selected.stageCut == 12,
          original.plan.stages.map(\.sourceRange) == [0..<16, 16..<32],
          original.plan.fingerprint == equal.plan.fingerprint,
          unequal.plan.fingerprint == expected.fingerprint,
          unequal.plan.fingerprint != original.plan.fingerprint,
          unequal.plan.stages.map(\.sourceRange) == [0..<12, 12..<32], componentCounts == [27, 45],
          unequal.configurationData == configuration, unequal.prompt == prompt, unequal.teacher == teacher,
          unequal.conservativeStateAndBoundaryBytes == original.conservativeStateAndBoundaryBytes else {
        throw ProbeError("Explicit stage cut changed default identity, local mapping, retained inputs or resource budget")
    }
    try QwenLayerStageComparisonAdmission.validatePlanBinding(omitted, inputs: original)
    try QwenLayerStageComparisonAdmission.validatePlanBinding(selected, inputs: unequal)
    var accepted = 3, rejected = 0
    func reject(_ label: String, message: String? = nil, _ action: () throws -> Void) throws {
        do { try action() } catch {
            if let message, !String(describing: error).contains(message) {
                throw ProbeError("Stage cut rejected \(label) for an unrelated reason: \(error)")
            }
            rejected += 1; return
        }
        throw ProbeError("Stage cut admitted " + label)
    }
    try reject("explicit cut changed after preflight", message: "Explicit stage cut differs") {
        try QwenLayerStageComparisonAdmission.validatePlanBinding(selected, inputs: original)
    }
    for value in ["0", "-1", "128", String(Int.max), "1.0", "true", "", "999999999999999999999999"] {
        try reject("invalid cut " + value) { _ = try Options(arguments: basic + ["--stage-cut", value]) }
    }
    try reject("missing cut") { _ = try Options(arguments: basic + ["--stage-cut"]) }
    try reject("duplicate cut", message: "Duplicate --stage-cut") {
        _ = try Options(arguments: basic + ["--stage-cut", "12", "--stage-cut", "16"])
    }
    for cut in [1, 2, 3, 5, 15, 29, 31, 32, 33, 127] {
        try reject("invalid range or phase \(cut)") {
            _ = try QwenLayerStageComparisonAdmission.preflight(Options(arguments: basic + ["--stage-cut", String(cut)]))
        }
    }
    // Programmatic Options mutation must not create a trapping Swift Range.
    for cut in [Int.min, -1, 0, 32, Int.max] {
        var invalid = selected; invalid.stageCut = cut
        try reject("mutated cut \(cut)") { _ = try QwenLayerStageComparisonAdmission.preflight(invalid) }
    }
    // Keep the Plan's deliberate allowance for a non-aligned final model end.
    var tail = text; tail["num_hidden_layers"] = 13
    tail["layer_types"] = (0..<13).map { ($0 + 1) % 4 == 0 ? "full_attention" : "linear_attention" }
    try JSONSerialization.data(withJSONObject: tail).write(to: configFile)
    let tailInput = try QwenLayerStageComparisonAdmission.preflight(Options(arguments: basic + ["--stage-cut", "4"]))
    guard tailInput.plan.stages.map(\.sourceRange) == [0..<4, 4..<13] else {
        throw ProbeError("Explicit cut changed the existing Plan final-end rules")
    }
    accepted += 1
    try reject("omitted odd-layer cut") { _ = try QwenLayerStageComparisonAdmission.preflight(omitted) }
    try configuration.write(to: configFile)

    let foreignModes: [Options.Mode] = [.baseline, .ffnTP, .worker, .workerTP, .qwenLayerStageCheck,
        .qwenLayerStageProfiledCheck, .qwenLayerStageRankCheck, .qwenLayerStageLookaheadCheck,
        .qwenLayerStagePrefillCheck, .qwenLayerStagePrefillRankCheck, .qwenLayerStageSoloPrefillCheck,
        .qwenLongPrefillReference, .qwenLongPrefillPairCheck, .qwenLongPrefillRankCheck, .qwenLongPrefillSoloCheck]
    for mode in foreignModes {
        try reject("foreign CLI mode " + mode.rawValue, message: "--stage-cut requires qwen-layer-stage-compare") {
            _ = try Options(arguments: basic + ["--stage-cut", "12", "--mode", mode.rawValue])
        }
    }
    // Direct helpers receive otherwise valid cloned options: the cut alone must fail.
    var rank = selected; rank.mode = .qwenLayerStageRankCheck
    rank.transport = .loopbackTest; rank.epoch = String(repeating: "b", count: 32)
    var lookahead = rank; lookahead.mode = .qwenLayerStageLookaheadCheck
    var prefill = selected; prefill.mode = .qwenLayerStagePrefillCheck
    prefill.decodeCount = 1; prefill.teacherTokensFile = nil
    var prefillRank = rank; prefillRank.mode = .qwenLayerStagePrefillRankCheck
    prefillRank.decodeCount = 1; prefillRank.teacherTokensFile = nil
    prefillRank.stagePrefillPolicy = .serial; prefillRank.stageLogitsDType = "bfloat16"
    var solo = prefill; solo.mode = .qwenLayerStageSoloPrefillCheck
    solo.soloReferenceFile = directory.appendingPathComponent("unread-reference.json")
    solo.soloReferenceSHA256 = String(repeating: "c", count: 64)
    solo.soloBaselineEvidenceSHA256 = String(repeating: "d", count: 64)
    let helpers: [(Options, (Options) throws -> Void)] = [
        (rank, QwenLayerStageRankAdmission.validateOptions),
        (lookahead, QwenLayerStageLookaheadAdmission.validateOptions),
        (prefill, QwenLayerStagePrefillAdmission.validateOptions),
        (prefillRank, QwenLayerStagePrefillRankAdmission.validateOptions),
        (solo, QwenLayerStageSoloPrefillCLIAdmission.validateOptions),
    ]
    for (input, validate) in helpers {
        var control = input; control.stageCut = nil
        try validate(control); accepted += 1
        try reject("mode-rewriting helper " + input.mode.rawValue, message: "--stage-cut is only admitted") {
            try validate(input)
        }
    }
    for (flag, value) in [("--prompt-tokens", "129"), ("--chunk-size", "33"), ("--decode-tokens", "5"),
        ("--repeats", "2"), ("--warmups", "1"), ("--timeout-seconds", "181"), ("--execution-path", "ordinary")] {
        try reject("preserved cap " + flag) { _ = try Options(arguments: basic + ["--stage-cut", "12", flag, value]) }
    }
    var large = text
    for (key, value) in [("num_hidden_layers", 128), ("linear_num_key_heads", 128),
        ("linear_num_value_heads", 128), ("linear_key_head_dim", 512), ("linear_value_head_dim", 512)] { large[key] = value }
    large["layer_types"] = (0..<128).map { ($0 + 1) % 4 == 0 ? "full_attention" : "linear_attention" }
    try JSONSerialization.data(withJSONObject: large).write(to: configFile)
    try reject("512 MiB named-state cap", message: "exceeds 512 MiB") {
        _ = try QwenLayerStageComparisonAdmission.preflight(selected)
    }
    struct Result: Encodable {
        let kind = "qwen_layer_stage_cut_admission_check", cpuOnly = true
        let acceptedFixtures: Int, rejectedFixtures: Int
        let defaultHalfPlanIdentityPreserved = true, explicitCutUsesExistingPlan = true
        let originalModeAndClonedHelperScopeChecked = true, existingResourceCapsPreserved = true
    }
    try emitJSON(Result(acceptedFixtures: accepted, rejectedFixtures: rejected))
}
