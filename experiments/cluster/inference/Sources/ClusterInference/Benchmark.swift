import Foundation
import MLX
import MLXLMCommon

struct RunResult: Codable {
    let iteration: Int
    let promptTokens: Int
    let generatedTokens: [Int]
    let localArgmaxTokens: [Int]
    let localArgmaxDisagreementCount: Int
    let decodeInputTokens: [Int]
    let prefillSeconds: Double
    let prefillTokensPerSecond: Double
    let decodeForwardCount: Int
    let decodeSeconds: Double
    let decodeTokensPerSecond: Double?
    let decodeStepSeconds: [Double]
    let peakMLXBytes: Int
    let activeMLXBytes: Int
}

struct Execution {
    let result: RunResult
    let logits: [[Float]]
}

func secondsSince(_ start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
}

func execute(
    loaded: LoadedModel, prompt: [Int], teacher: [Int]?, options: Options,
    iteration: Int, collectLogits: Bool, collective: Collective? = nil,
    onToken: ((Int, Int) throws -> Void)? = nil
) throws -> Execution {
    Memory.peakMemory = 0
    let session = makeRequestModelSession(loaded: loaded, options: options)
    defer { try? session.close() }
    let initialReductionCount = collective?.modelReductionCount ?? 0
    var generated: [Int] = []
    var localArgmax: [Int] = []
    var decodeInputs: [Int] = []
    var disagreements = 0
    var allLogits: [[Float]] = []
    var firstLogits: MLXArray!
    var sampled: MLXArray!
    var stepTimes: [Double] = []
    func select(_ sampled: MLXArray, step: Int) throws -> Int {
        let local = sampled.item(Int.self)
        let selected: Int
        if let collective {
            selected = try collective.selectToken(localArgmax: local, sequence: iteration, step: step)
        } else {
            guard (0..<loaded.vocabularySize).contains(local) else { throw ProbeError("Selected token is outside the vocabulary") }
            selected = local
        }
        localArgmax.append(local)
        if local != selected { disagreements += 1 }
        return selected
    }
    // The first result includes every prompt token, including the final partial chunk.
    let prefillStart = DispatchTime.now().uptimeNanoseconds
    collective?.beginTokenSequence(sequence: iteration, vocabularySize: loaded.vocabularySize,
                                   outputCount: options.decodeCount)
    try MLX.withError { error in
        firstLogits = try session.prefill(prompt, check: { try error.check() })
        sampled = argMax(firstLogits)
        eval(sampled!, firstLogits!)
        try error.check()
    }
    generated.append(try select(sampled, step: 0))
    let prefillTime = secondsSince(prefillStart)
    try onToken?(0, generated[0])
    if collectLogits { allLogits.append(firstLogits.asType(.float32).asArray(Float.self)) }
    firstLogits = nil
    // Exactly N-1 decode forwards produce N output tokens; there is no hidden extra forward.
    for step in 0..<(options.decodeCount - 1) {
        let token = teacher?[step] ?? generated.last!
        decodeInputs.append(token)
        var logits: MLXArray!
        let start = DispatchTime.now().uptimeNanoseconds
        try MLX.withError { error in
            logits = try session.decode(token, check: { try error.check() })
            sampled = argMax(logits)
            eval(sampled!, logits!)
            try error.check()
        }
        generated.append(try select(sampled, step: step + 1))
        stepTimes.append(secondsSince(start))
        try onToken?(step + 1, generated.last!)
        if collectLogits { allLogits.append(logits.asType(.float32).asArray(Float.self)) }
    }
    Stream.gpu.synchronize()
    Stream.cpu.synchronize()
    if options.executionPath == .cbv2Contiguous, let collective {
        let forwards = (prompt.count - 1) / options.chunkSize + options.decodeCount
        let perForward = loaded.layerCount * (options.partition == .full ? 2 : 1)
        let (expected, overflow) = forwards.multipliedReportingOverflow(by: perForward)
        guard !overflow, collective.modelReductionCount - initialReductionCount == expected else {
            throw ProbeError("CBv2 model bypassed or duplicated an expected partition reduction")
        }
        log("CBv2 model reduction hooks verified: \(expected) across \(forwards) forwards")
    }
    let decodeTime = stepTimes.reduce(0, +)
    let result = RunResult(
        iteration: iteration, promptTokens: prompt.count, generatedTokens: generated,
        localArgmaxTokens: localArgmax, localArgmaxDisagreementCount: disagreements,
        decodeInputTokens: decodeInputs,
        prefillSeconds: prefillTime, prefillTokensPerSecond: Double(prompt.count) / prefillTime,
        decodeForwardCount: stepTimes.count, decodeSeconds: decodeTime,
        decodeTokensPerSecond: stepTimes.isEmpty ? nil : Double(stepTimes.count) / decodeTime,
        decodeStepSeconds: stepTimes, peakMLXBytes: Memory.peakMemory,
        activeMLXBytes: Memory.activeMemory)
    try session.close()
    return Execution(result: result, logits: allLogits)
}

struct ParityResult: Encodable {
    let kind = "local_partition_parity"
    let comparedLogits: Int
    let maxAbsoluteError: Double
    let relativeRMSError: Double
    let greedyTokensEqual: Bool
    let passed: Bool
}

func compare(_ baseline: Execution, _ partitioned: Execution) throws -> ParityResult {
    let a = baseline.logits.flatMap { $0 }
    let b = partitioned.logits.flatMap { $0 }
    guard !a.isEmpty, a.count == b.count else { throw ProbeError("Parity logits shape mismatch") }
    var maxError = 0.0, squareError = 0.0, squareReference = 0.0
    for (reference, candidate) in zip(a, b) {
        guard reference.isFinite, candidate.isFinite else { throw ProbeError("Nonfinite parity logits") }
        let difference = Double(reference) - Double(candidate)
        maxError = max(maxError, abs(difference))
        squareError += difference * difference
        squareReference += Double(reference) * Double(reference)
    }
    let relativeRMS = sqrt(squareError / max(squareReference, 1e-30))
    let tokensEqual = baseline.result.generatedTokens == partitioned.result.generatedTokens
    return ParityResult(
        comparedLogits: a.count, maxAbsoluteError: maxError, relativeRMSError: relativeRMS,
        greedyTokensEqual: tokensEqual,
        passed: relativeRMS < 1e-4 && maxError < 1e-3 && tokensEqual)
}
