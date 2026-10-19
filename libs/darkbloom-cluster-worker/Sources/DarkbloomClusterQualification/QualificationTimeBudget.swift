import DarkbloomClusterProtocol
import Foundation

/// Time budgets of one request, scaled with its prompt length from the rates
/// measured on the slower Mac running the model alone. The owner's watchdogs
/// do the same (ThunderMLX: max(base, tokens / 60 + 120 s)); a fixed budget
/// sized for 8,192 tokens is far too short for 30,000 on the slower Mac and
/// far too long for 1,000.
///
/// Prefill cost per token grows with the context it attends over. With `r`
/// the short-context rate and `D` the context at which a token costs twice as
/// much as at the start, a prompt of `n` tokens takes `n / r * (1 + n / D)`;
/// the last frame of it, `chunk / r * (1 + 2n / D)`. Budgets add a margin on
/// top: they bound a run that has gone wrong, they are not a forecast.
public struct QualificationTimeBudget: Equatable, Sendable {
    /// Prompt tokens per second, the slower Mac alone, prompts of 1,024 to 8,192.
    public let slowestPrefillTokensPerSecond: Double
    /// Output tokens per second, the slower decoding Mac alone.
    public let slowestDecodeTokensPerSecond: Double
    /// The context at which a prompt token costs twice what it costs at the start.
    public let attentionDoublingTokens: Double

    public static let baseSeconds = 10.0
    public static let margin = 1.5
    public static let decodeMargin = 2.0
    public static let requestSlackSeconds = 10.0
    public static let lifetimeSlackSeconds = 30
    /// The collective progress limit is never below the value every earlier
    /// run used, and is at least this many times the slowest frame.
    public static let minimumProgressMilliseconds = 60_000
    public static let framesPerProgressLimit = 10.0

    public init(slowestPrefillTokensPerSecond: Double, slowestDecodeTokensPerSecond: Double,
                attentionDoublingTokens: Double) {
        self.slowestPrefillTokensPerSecond = slowestPrefillTokensPerSecond
        self.slowestDecodeTokensPerSecond = slowestDecodeTokensPerSecond
        self.attentionDoublingTokens = attentionDoublingTokens
    }

    /// Measured rows (driver clock, median after one warm-up, registered weights):
    /// - 9B: Mac A alone 1,030 to 1,062 prompt tok/s at 1,024 to 8,192 tokens;
    ///   decode 72 tok/s on Mac A, 77 to 81 on Mac B.
    /// - 27B: Mac A alone 307 to 318 prompt tok/s at 1,024 to 8,192 tokens;
    ///   decode 24 to 28 tok/s on Mac B, 29 to 31 on Mac A.
    /// The doubling context is 32,768 for both until the long-prompt runs
    /// measure it; a FLOP count puts it above 100,000 for these geometries,
    /// so this is the cautious side.
    /// The other families' rows are rounded down from their workers' figures
    /// at 4,096 to 8,192 prompt tokens (`T/evidence/<family>-20261009`, the
    /// slower Mac alone where it was run, else the pair): A3B Mac A reference
    /// clock 1,166 to 1,813 prompt tok/s, decode 49 to 61; Bonsai Mac A 280 to
    /// 300, decode 30; Gemma 4 QAT Mac A 1,757, decode 57; MiMo the pair 380,
    /// decode 33. Nemotron's and GPT-OSS's slower Mac alone were not measured;
    /// their rows sit well below the pair's 2,700 and 4,400 prompt tok/s.
    public static let measured: [String: QualificationTimeBudget] = [
        "registered_qwen35_9b": .init(slowestPrefillTokensPerSecond: 1030, slowestDecodeTokensPerSecond: 72,
            attentionDoublingTokens: 32_768),
        "registered_qwen38_27b": .init(slowestPrefillTokensPerSecond: 307, slowestDecodeTokensPerSecond: 24,
            attentionDoublingTokens: 32_768),
        "registered_qwen35_35b_a3b": .init(slowestPrefillTokensPerSecond: 1100, slowestDecodeTokensPerSecond: 45,
            attentionDoublingTokens: 32_768),
        "registered_qwen36_35b_a3b": .init(slowestPrefillTokensPerSecond: 1100, slowestDecodeTokensPerSecond: 45,
            attentionDoublingTokens: 32_768),
        "registered_ternary_bonsai_2_27b": .init(slowestPrefillTokensPerSecond: 270, slowestDecodeTokensPerSecond: 28,
            attentionDoublingTokens: 32_768),
        "registered_nemotron35_lightning": .init(slowestPrefillTokensPerSecond: 1000, slowestDecodeTokensPerSecond: 45,
            attentionDoublingTokens: 32_768),
        "registered_gemma4_26b_qat_4bit": .init(slowestPrefillTokensPerSecond: 1500, slowestDecodeTokensPerSecond: 50,
            attentionDoublingTokens: 32_768),
        "registered_gemma4_26b": .init(slowestPrefillTokensPerSecond: 1200, slowestDecodeTokensPerSecond: 40,
            attentionDoublingTokens: 32_768),
        "registered_gemma4_26b_8bit": .init(slowestPrefillTokensPerSecond: 1200, slowestDecodeTokensPerSecond: 40,
            attentionDoublingTokens: 32_768),
        "registered_gpt_oss_20b": .init(slowestPrefillTokensPerSecond: 1000, slowestDecodeTokensPerSecond: 50,
            attentionDoublingTokens: 32_768),
        // GLM-5.3-Flash: not yet measured; deliberately slow rates (longer timeouts).
        "registered_glm53_flash": .init(slowestPrefillTokensPerSecond: 100, slowestDecodeTokensPerSecond: 5,
            attentionDoublingTokens: 32_768),
        "registered_mimo_v26_flash_mopd": .init(slowestPrefillTokensPerSecond: 250, slowestDecodeTokensPerSecond: 20,
            attentionDoublingTokens: 32_768),
    ]

    public static func forModel(_ modelID: String) -> QualificationTimeBudget? { measured[modelID] }

    public func prefillSeconds(promptTokens n: Int) -> Double {
        Double(n) / slowestPrefillTokensPerSecond * (1 + Double(n) / attentionDoublingTokens)
    }

    public func firstTokenSeconds(promptTokens: Int) -> Int {
        Int((Self.baseSeconds + Self.margin * prefillSeconds(promptTokens: promptTokens)).rounded(.up))
    }

    public func requestSeconds(promptTokens: Int, outputTokens: Int) -> Int {
        let decode = Self.decodeMargin * Double(outputTokens) / slowestDecodeTokensPerSecond
        return firstTokenSeconds(promptTokens: promptTokens) + Int((decode + Self.requestSlackSeconds).rounded(.up))
    }

    /// Startup, then every request one after another, bounded by the protocol.
    public func lifetimeSeconds(promptTokens: Int, outputTokens: Int, repetitions: Int, startupSeconds: Int) -> Int {
        let total = startupSeconds + max(1, repetitions) * requestSeconds(promptTokens: promptTokens, outputTokens: outputTokens)
            + Self.lifetimeSlackSeconds
        return min(Int(ClusterWorkerLimits.deadlineNanoseconds / 1_000_000_000), total)
    }

    /// The longest one rank may wait in a collective: several of the slowest
    /// frame (the last prompt frame, attending over the whole prompt), and
    /// never below the earlier fixed limit.
    public func progressTimeoutMilliseconds(promptTokens: Int, chunkTokens: Int) -> Int {
        let frame = Double(min(chunkTokens, promptTokens)) / slowestPrefillTokensPerSecond
            * (1 + 2 * Double(promptTokens) / attentionDoublingTokens)
        return min(600_000, max(Self.minimumProgressMilliseconds, Int((Self.framesPerProgressLimit * frame * 1000).rounded(.up))))
    }
}
