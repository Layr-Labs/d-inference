import DarkbloomClusterProtocol

/// A target-verified round can finish before the client grants credit for all
/// of its tokens. Keep that bounded suffix request-local; returning one value
/// consumes one ordinary driver credit and never advances native state again.
///
/// A row may also run its next round ahead of its credits, from its own settled
/// carry, while at most `depth` of its tokens still wait (cohort synchronization:
/// rows that started a step apart verify together instead of alternately). That
/// round's input is this queue's last token and its tokens follow the queue, so
/// the queue never holds more than `capacity(depth:)` settled selections.
struct QwenTensorParallelAcceptedSelections {
    struct Selection {
        let token: Int
        let logprobs: ClusterWorkerTokenLogprobs?
    }
    private var values: [Selection] = []
    private var expectedInput: Int?
    var isEmpty: Bool { values.isEmpty }
    var count: Int { values.count }

    /// Two settled rounds: at most `depth` queued tokens, then one full window.
    static func capacity(depth: Int) -> Int { 2 * depth + 1 }

    mutating func append(input: Int, tokens: [Int], logprobs: [ClusterWorkerTokenLogprobs],
                         depth: Int, vocabulary: Int) throws {
        guard (1...4).contains(depth), (1...(depth + 1)).contains(tokens.count),
              logprobs.isEmpty || logprobs.count == tokens.count,
              (0..<vocabulary).contains(input), tokens.allSatisfy({ (0..<vocabulary).contains($0) }),
              // An empty queue takes a round on the driver's next input; a
              // queued suffix only a round that continues its own last token.
              isEmpty ? expectedInput == nil : (values.count <= depth && values.last?.token == input),
              values.count + tokens.count <= Self.capacity(depth: depth) else {
            throw ProbeError("Qwen TP accepted selection queue exceeds its settled round")
        }
        if isEmpty { expectedInput = input }
        values += tokens.enumerated().map { Selection(token: $0.element, logprobs: logprobs.isEmpty ? nil : logprobs[$0.offset]) }
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
