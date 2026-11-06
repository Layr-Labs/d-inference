import Foundation

/// Foundation/CryptoKit-only prospective checks. The caller supplies retained
/// configuration bytes. No fixture loads weights, constructs MLX arrays or reads
/// the environment, and this draft has not been Swift-compiled by its author.
struct QwenLongPrefillBudgetCheckResult: Encodable {
    let kind = "qwen_long_prefill_budget_check"
    let schemaVersion = 1
    let acceptedChecks: Int, rejectedChecks: Int
    let accepted: [String], rejected: [String]
    let registered: QwenRegistered9BLongPrefillAdmission.Receipt
    let arithmetic: QwenLongPrefillArithmeticEnvironment.Receipt
    let legacy512MiBCeilingChanged = false
    let nativeOrGPUWorkPerformed = false
}

func checkQwenLongPrefillBudget(configuration: Data) throws -> QwenLongPrefillBudgetCheckResult {
    var accepted: [String] = [], rejected: [String] = []
    func check(_ name: String, _ value: Bool) throws {
        guard value else { throw QwenLongPrefillBudgetError.invalid("Budget selfcheck failed: " + name) }
        accepted.append(name)
    }
    func reject(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(name); return }
        throw QwenLongPrefillBudgetError.invalid("Budget selfcheck accepted invalid case: " + name)
    }
    func geometry(layers: Int = 32, interval: Int = 4, hidden: Int = 4096,
                  query: Int = 16, kv: Int = 4, head: Int = 256,
                  keyHeads: Int = 16, valueHeads: Int = 32, key: Int = 128,
                  value: Int = 128, kernel: Int = 4) throws -> QwenLongPrefillBudgetGeometry {
        try .init(layers: layers, fullAttentionInterval: interval, hiddenSize: hidden,
            queryHeads: query, kvHeads: kv, headDimension: head,
            linearKeyHeads: keyHeads, linearValueHeads: valueHeads,
            linearKeyDimension: key, linearValueDimension: value, convolutionKernel: kernel)
    }
    func registered(config: Data? = nil, artifact: String = QwenRegistered9BLongPrefillAdmission.expectedArtifactAggregateSHA256,
                    prompt: Int = 8192, chunk: Int = 512, output: Int = 1,
                    batch: Int = 1, teacher: Int = 0, dtype: String = "bfloat16", bf16: Bool = true)
        throws -> QwenRegistered9BLongPrefillAdmission.Receipt {
        try QwenRegistered9BLongPrefillAdmission.admit(configuration: config ?? configuration,
            expectedArtifactAggregateSHA256: artifact, promptCount: prompt, chunkSize: chunk,
            outputCount: output, batchSize: batch, teacherTokenCount: teacher,
            nativeDType: dtype, bf16ConversionEnabled: bf16)
    }

    let pin = try registered()
    let budget = pin.budget
    try check("registered exact 8192/512/1", pin.frameCount == 16 && budget.maximumTokens == 8193)
    try check("registered independent term vector", [budget.convolutionBytesPerLayer, budget.ssmBytesPerLayer,
        budget.kvCapacityBytesPerAttentionLayer, budget.boundaryBytes,
        budget.threeRecurrentGenerationsBytes, budget.allKVCapacityAndOffsetsBytes,
        budget.largestSingleHostStateComponentBytes, budget.twoBoundaryArraysBytes,
        budget.conservativeStateAndBoundaryBytes] == [98304, 2097152, 67117056, 8388608,
        158072832, 536936480, 33558528, 16777216, 745345056])
    try check("separate 768 MiB ceiling", pin.namedTensorByteCeiling == 805306368 &&
        budget.conservativeStateAndBoundaryBytes <= pin.namedTensorByteCeiling)
    try check("old 512 MiB gate would reject", budget.conservativeStateAndBoundaryBytes > 512 * 1024 * 1024)
    let zeroHistory = try QwenLongPrefillTensorBudget.estimate(geometry: geometry(kernel: 1), maximumTokens: 1, chunkSize: 1)
    try check("kernel one has zero convolution history", zeroHistory.convolutionBytesPerLayer == 0)
    let cap = try QwenLongPrefillTensorBudget.estimate(geometry: geometry(), maximumTokens: 32768, chunkSize: 512)
    try check("generic formula is not registered resource admission", cap.conservativeStateAndBoundaryBytes > pin.namedTensorByteCeiling)
    try check("checked zero product", try QwenLongPrefillCheckedBytes.product([4, 0, 8192]) == 0)
    try check("checked Int maximum", try QwenLongPrefillCheckedBytes.sum([Int.max, 0]) == Int.max)

    try reject("negative product") { _ = try QwenLongPrefillCheckedBytes.product([-1]) }
    try reject("product overflow") { _ = try QwenLongPrefillCheckedBytes.product([Int.max, 2]) }
    try reject("negative sum") { _ = try QwenLongPrefillCheckedBytes.sum([-1]) }
    try reject("sum overflow") { _ = try QwenLongPrefillCheckedBytes.sum([Int.max, 1]) }
    try reject("layer interval misalignment") { _ = try geometry(layers: 31) }
    try reject("zero interval") { _ = try geometry(interval: 0) }
    try reject("nondivisible query heads") { _ = try geometry(query: 15) }
    try reject("nondivisible linear heads") { _ = try geometry(valueHeads: 31) }
    try reject("unvectorized GDN key dimension") { _ = try geometry(key: 127) }
    try reject("hidden width overflow") { _ = try geometry(hidden: 8193) }
    try reject("kernel zero") { _ = try geometry(kernel: 0) }
    try reject("negative token capacity") { _ = try QwenLongPrefillTensorBudget.estimate(geometry: geometry(), maximumTokens: -1, chunkSize: 1) }
    try reject("token capacity above native contract") { _ = try QwenLongPrefillTensorBudget.estimate(geometry: geometry(), maximumTokens: 32769, chunkSize: 1) }
    try reject("chunk above new bound") { _ = try QwenLongPrefillTensorBudget.estimate(geometry: geometry(), maximumTokens: 8193, chunkSize: 513) }
    try reject("chunk exceeds capacity") { _ = try QwenLongPrefillTensorBudget.estimate(geometry: geometry(), maximumTokens: 1, chunkSize: 2) }
    try reject("wrong config exact bytes") { _ = try registered(config: configuration + Data([0x20])) }
    try reject("missing config") { _ = try registered(config: Data()) }
    try reject("oversized config") { _ = try registered(config: Data(repeating: 0, count: 1_048_577)) }
    try reject("wrong artifact pin") { _ = try registered(artifact: String(repeating: "0", count: 64)) }
    try reject("generic small prompt is not registered execution") { _ = try registered(prompt: 65) }
    try reject("wrong chunk") { _ = try registered(chunk: 32) }
    try reject("decode output") { _ = try registered(output: 2) }
    try reject("multiple batches") { _ = try registered(batch: 2) }
    try reject("teacher input") { _ = try registered(teacher: 1) }
    try reject("wrong native dtype") { _ = try registered(dtype: "float32") }
    try reject("BF16 conversion disabled") { _ = try registered(bf16: false) }

    let env = QwenLongPrefillArithmeticEnvironment.requiredValues
    let arithmetic = try QwenLongPrefillArithmeticEnvironment.admit(env)
    try check("exact arithmetic contract", arithmetic.full512TokenChunkQueryBlocks == 4)
    for name in env.keys.sorted() {
        var missing = env; missing.removeValue(forKey: name)
        try reject("missing explicit " + name) { _ = try QwenLongPrefillArithmeticEnvironment.admit(missing) }
        for spelling in ["0", "1.0", "1e0", "true", " 1", "1 ", ""] {
            var wrong = env; wrong[name] = spelling
            try reject("noncanonical " + name + "=" + spelling) { _ = try QwenLongPrefillArithmeticEnvironment.admit(wrong) }
        }
    }
    for name in QwenLongPrefillArithmeticEnvironment.requiredAbsentNames {
        for override in ["", "0", "1", "128"] {
            var present = env; present[name] = override
            try reject("forbidden override " + name + "=" + override) { _ = try QwenLongPrefillArithmeticEnvironment.admit(present) }
        }
    }
    var unrelated = env; unrelated["UNRELATED_NONSECRET_TEST_SETTING"] = "preserved"
    try check("no unrelated environment capture", try QwenLongPrefillArithmeticEnvironment.admit(unrelated) == arithmetic)
    return .init(acceptedChecks: accepted.count, rejectedChecks: rejected.count,
        accepted: accepted, rejected: rejected, registered: pin, arithmetic: arithmetic)
}
