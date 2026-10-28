import Foundation

/// CPU metadata and option checks only. Never constructs a collective or model.
func checkQwenLayerStageRankCutAdmission() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stage-rank-cut-check-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let promptFile = directory.appendingPathComponent("prompt.json")
    let teacherFile = directory.appendingPathComponent("teacher.json")
    let basic = ["--mode", "qwen-layer-stage-rank-check", "--model-dir", directory.path,
        "--artifact-aggregate-sha256", String(repeating: "a", count: 64),
        "--transport", "loopback-test", "--epoch", String(repeating: "b", count: 32),
        "--execution-path", "cbv2-contiguous", "--tokens-file", promptFile.path,
        "--teacher-tokens-file", teacherFile.path, "--prompt-tokens", "65", "--chunk-size", "32",
        "--decode-tokens", "4", "--repeats", "1", "--warmups", "0", "--timeout-seconds", "170"]
    let omitted = try Options(arguments: basic)
    let selected = try Options(arguments: basic + ["--stage-cut", "12"])
    let explicitHalf = try Options(arguments: basic + ["--stage-cut", "16"])
    var text = try JSONSerialization.jsonObject(with: syntheticConfiguration(options: omitted)) as! [String: Any]
    text["num_hidden_layers"] = 32; text["full_attention_interval"] = 4
    text["layer_types"] = (0..<32).map { ($0 + 1) % 4 == 0 ? "full_attention" : "linear_attention" }
    let configuration = try JSONSerialization.data(withJSONObject: text, options: [.sortedKeys])
    try configuration.write(to: directory.appendingPathComponent("config.json"))
    let prompt = (0..<65).map { 3 + (($0 * 17 + 7) % 509) }, teacher = [12, 25, 38]
    try JSONEncoder().encode(prompt).write(to: promptFile)
    try JSONEncoder().encode(teacher).write(to: teacherFile)
    let original = try QwenLayerStageRankAdmission.preflight(omitted)
    let unequal = try QwenLayerStageRankAdmission.preflight(selected)
    let equal = try QwenLayerStageRankAdmission.preflight(explicitHalf)
    var comparisonOptions = selected
    comparisonOptions.mode = .qwenLayerStageCompare; comparisonOptions.transport = .jaccl; comparisonOptions.epoch = nil
    let comparison = try QwenLayerStageComparisonAdmission.preflight(comparisonOptions)
    let selectedRequestID = try QwenLayerStageRankAdmission.requestID(epoch: selected.epoch!)
    let originalRequestID = try QwenLayerStageRankAdmission.requestID(epoch: omitted.epoch!)
    guard omitted.stageCut == nil, selected.stageCut == 12,
          original.plan.stages.map(\.sourceRange) == [0..<16, 16..<32],
          original.plan.fingerprint == equal.plan.fingerprint,
          unequal.plan.stages.map(\.sourceRange) == [0..<12, 12..<32],
          unequal.plan.fingerprint == comparison.plan.fingerprint,
          unequal.plan.fingerprint != original.plan.fingerprint,
          unequal.configurationData == configuration, unequal.prompt == prompt, unequal.teacher == teacher,
          unequal.conservativeStateAndBoundaryBytes == original.conservativeStateAndBoundaryBytes,
          unequal.plan.stages.map({ $0.layers.reduce(0) { $0 + ($1.kind == "full_attention" ? 3 : 2) } }) == [27, 45],
          selectedRequestID == originalRequestID else {
        throw ProbeError("Rank cut changed default/source/request identity or full state ownership")
    }
    try QwenLayerStageComparisonAdmission.validatePlanBinding(omitted, inputs: original)
    try QwenLayerStageComparisonAdmission.validatePlanBinding(selected, inputs: unequal)
    try QwenLayerStageComparisonAdmission.validatePlanBinding(explicitHalf, inputs: equal)
    var accepted = 4, rejected = 0
    func reject(_ label: String, message: String? = nil, _ body: () throws -> Void) throws {
        do { try body() } catch {
            if let message, !String(describing: error).contains(message) {
                throw ProbeError("Rank cut rejected \(label) for an unrelated reason: \(error)")
            }
            rejected += 1; return
        }
        throw ProbeError("Rank cut admitted " + label)
    }
    for value in ["0", "-1", "128", String(Int.max), "1.0", "true", "", "999999999999999999999999"] {
        try reject("invalid cut " + value) { _ = try Options(arguments: basic + ["--stage-cut", value]) }
    }
    try reject("missing cut") { _ = try Options(arguments: basic + ["--stage-cut"]) }
    try reject("duplicate cut", message: "Duplicate --stage-cut") {
        _ = try Options(arguments: basic + ["--stage-cut", "12", "--stage-cut", "16"])
    }
    for cut in [1, 3, 5, 31, 32, 127] {
        try reject("cut outside source/phase \(cut)") {
            _ = try QwenLayerStageRankAdmission.preflight(Options(arguments: basic + ["--stage-cut", String(cut)]))
        }
    }
    for cut in [Int.min, -1, 0, Int.max] {
        var changed = selected; changed.stageCut = cut
        try reject("mutated range \(cut)") { _ = try QwenLayerStageRankAdmission.preflight(changed) }
    }
    // These are the exact pure guards invoked before the runner creates Collective.
    try reject("selected cut with stale half plan", message: "Explicit stage cut differs") {
        try QwenLayerStageComparisonAdmission.validatePlanBinding(selected, inputs: original)
    }
    try reject("selected half with stale unequal plan", message: "Explicit stage cut differs") {
        try QwenLayerStageComparisonAdmission.validatePlanBinding(explicitHalf, inputs: unequal)
    }
    let foreignModes: [Options.Mode] = [.baseline, .ffnTP, .worker, .workerTP, .qwenLayerStageCheck,
        .qwenLayerStageProfiledCheck, .qwenLayerStageLookaheadCheck, .qwenLayerStagePrefillCheck,
        .qwenLayerStagePrefillRankCheck, .qwenLayerStageSoloPrefillCheck, .qwenLongPrefillReference,
        .qwenLongPrefillPairCheck, .qwenLongPrefillRankCheck, .qwenLongPrefillSoloCheck]
    for mode in foreignModes {
        try reject("foreign CLI mode " + mode.rawValue, message: "--stage-cut requires") {
            _ = try Options(arguments: basic + ["--stage-cut", "12", "--mode", mode.rawValue])
        }
    }
    var lookahead = selected; lookahead.mode = .qwenLayerStageLookaheadCheck
    var prefill = comparisonOptions; prefill.mode = .qwenLayerStagePrefillCheck
    prefill.decodeCount = 1; prefill.teacherTokensFile = nil
    var prefillRank = selected; prefillRank.mode = .qwenLayerStagePrefillRankCheck
    prefillRank.decodeCount = 1; prefillRank.teacherTokensFile = nil
    prefillRank.stagePrefillPolicy = .serial; prefillRank.stageLogitsDType = "bfloat16"
    var solo = prefill; solo.mode = .qwenLayerStageSoloPrefillCheck
    solo.soloReferenceFile = directory.appendingPathComponent("unread-reference.json")
    solo.soloReferenceSHA256 = String(repeating: "c", count: 64)
    solo.soloBaselineEvidenceSHA256 = String(repeating: "d", count: 64)
    let helpers: [(Options, (Options) throws -> Void)] = [
        (lookahead, QwenLayerStageLookaheadAdmission.validateOptions),
        (prefill, QwenLayerStagePrefillAdmission.validateOptions),
        (prefillRank, QwenLayerStagePrefillRankAdmission.validateOptions),
        (solo, QwenLayerStageSoloPrefillCLIAdmission.validateOptions),
    ]
    for (input, validate) in helpers {
        var control = input; control.stageCut = nil
        try validate(control); accepted += 1
        try reject("foreign mode-rewriting helper " + input.mode.rawValue, message: "--stage-cut is only admitted") {
            try validate(input)
        }
    }
    for (flag, value) in [("--transport", "jaccl"), ("--epoch", "invalid"),
        ("--prompt-tokens", "129"), ("--chunk-size", "33"), ("--decode-tokens", "5"),
        ("--warmups", "1"), ("--repeats", "2"), ("--timeout-seconds", "181"),
        ("--execution-path", "ordinary"), ("--stage-prefill-policy", "serial_v1")] {
        try reject("preserved gate " + flag) { _ = try Options(arguments: basic + ["--stage-cut", "12", flag, value]) }
    }
    struct Result: Encodable {
        let kind = "qwen_layer_stage_rank_cut_admission_check", cpuOnly = true
        let acceptedFixtures: Int, rejectedFixtures: Int
        let originalModeRestricted = true, foreignClonedHelpersRejected = true
        let defaultHalfPlanIdentityPreserved = true, explicitCutBoundBeforeCollective = true
        let existingRequestStorageArithmeticAndTransportGatesPreserved = true
        let collectiveOrModelConstructed = false, nativeExecutionQualified = false
    }
    try emitJSON(Result(acceptedFixtures: accepted, rejectedFixtures: rejected))
}
