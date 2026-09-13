import Foundation
import MLXLMCommon

extension Input {
    /// Concurrent copies change only their evidence label, never sampler knobs.
    func renamed(_ name: String) -> Input {
        Input(name: name, kind: kind, tokens: tokens, maxTokens: maxTokens,
              promptRenderDate: promptRenderDate, sampling: sampling)
    }
}

enum BenchmarkSampling {
    static func record(_ sampling: CBv2SamplingParams) -> [String: Any] {
        ["temperature": sampling.temperature, "top_p": sampling.topP,
         "top_k": sampling.topK, "min_p": sampling.minP,
         "seed": sampling.seed as Any? ?? NSNull(),
         "repetition_penalty": sampling.repetitionPenalty,
         "repetition_context_size": sampling.repetitionContextSize,
         "frequency_penalty": sampling.frequencyPenalty,
         "presence_penalty": sampling.presencePenalty,
         "logit_bias": Dictionary(uniqueKeysWithValues: sampling.logitBias.map { (String($0.key), $0.value) }),
         "top_logprobs": sampling.topLogprobs]
    }

    static func requireGreedyDiagnostics(_ inputs: [Input], enabled: Bool) throws {
        guard enabled else { return }
        for input in inputs {
            let sampling = input.sampling
            guard sampling.temperature == 0, sampling.repetitionPenalty == 1,
                sampling.frequencyPenalty == 0, sampling.presencePenalty == 0,
                sampling.logitBias.isEmpty, sampling.topLogprobs == 0 else {
                throw RadixBenchmark.Failure.message(
                    "explicit diagnostics require untransformed greedy sampling: \(input.name)")
            }
        }
    }
}
