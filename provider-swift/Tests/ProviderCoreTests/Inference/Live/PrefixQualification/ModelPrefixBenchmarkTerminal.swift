import MLXLMCommon

/// An unsuccessful native terminal may have no retirement acknowledgement.
/// Reject it before waiting for normal completion so the fixture's throwing
/// shutdown can report the actual retained fault and preserve its resources.
enum ModelPrefixBenchmarkTerminal {
    enum Failure: Error, Equatable {
        case missingUsage
        case incompleteOutput
    }

    static func completeSuccessfulRequest(
        finish: CBv2FinishReason?, usage: CBv2Usage?, outputCount: Int,
        expectedOutputCount: Int, complete: () async -> Void
    ) async throws -> CBv2Usage {
        guard let usage else { throw Failure.missingUsage }
        guard finish == .length, outputCount == expectedOutputCount else {
            throw Failure.incompleteOutput
        }
        await complete()
        return usage
    }
}
