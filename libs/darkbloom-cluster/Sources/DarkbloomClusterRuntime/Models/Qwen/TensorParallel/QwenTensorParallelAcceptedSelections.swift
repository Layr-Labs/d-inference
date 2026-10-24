import DarkbloomClusterProtocol

/// A target-verified round can finish before the client grants credit for all
/// of its tokens. Keep that bounded suffix request-local; returning one value
/// consumes one ordinary driver credit and never advances native state again.
struct QwenTensorParallelAcceptedSelections {
    struct Selection {
        let token: Int
        let logprobs: ClusterWorkerTokenLogprobs?
    }
    private var values: [Selection] = []
    private var expectedInput: Int?
    var isEmpty: Bool { values.isEmpty }
    var count: Int { values.count }

    mutating func append(input: Int, tokens: [Int], logprobs: [ClusterWorkerTokenLogprobs],
                         depth: Int, vocabulary: Int) throws {
        guard isEmpty, expectedInput == nil, (1...4).contains(depth),
              (1...(depth + 1)).contains(tokens.count),
              logprobs.isEmpty || logprobs.count == tokens.count,
              (0..<vocabulary).contains(input), tokens.allSatisfy({ (0..<vocabulary).contains($0) }) else {
            throw ProbeError("Qwen TP accepted selection queue exceeds its settled round")
        }
        values = tokens.enumerated().map { .init(token: $0.element, logprobs: logprobs.isEmpty ? nil : logprobs[$0.offset]) }
        expectedInput = input
    }

    mutating func take(input: Int) throws -> Selection {
        guard expectedInput == input, !values.isEmpty else { throw ProbeError("Qwen TP accepted suffix differs from selected history") }
        let value = values.removeFirst()
        expectedInput = values.isEmpty ? nil : value.token
        return value
    }

    mutating func removeAll() { values.removeAll(); expectedInput = nil }
}

/// The head is resident once per LOAD; every admitted eligible text lane owns
/// its own assistant pages and trusted history. Admission must price this
/// complete policy before supplying it to the native executor.
struct QwenTensorParallelBatchAssistant {
    let head: QwenTensorParallelMTPHead
    let depth: Int
    let prefix: QwenTensorParallelMTPPrefixCache?
    let prefixBudget: QwenTensorParallelMTPPrefixBudget
    let allocationBound: (Int) throws -> Int
    /// Nil preserves the existing singleton-ready-set policy. A wider target
    /// cohort requires the full dedicated quote, never a raw lane-count flag.
    let cohortBudget: QwenTensorParallelBatchMTPBudget?

    init(head: QwenTensorParallelMTPHead, depth: Int, prefix: QwenTensorParallelMTPPrefixCache?,
         prefixBudget: QwenTensorParallelMTPPrefixBudget, allocationBound: @escaping (Int) throws -> Int,
         cohortBudget: QwenTensorParallelBatchMTPBudget? = nil) {
        self.head = head; self.depth = depth; self.prefix = prefix; self.prefixBudget = prefixBudget
        self.allocationBound = allocationBound; self.cohortBudget = cohortBudget
    }
}
