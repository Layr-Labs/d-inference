import Foundation

/// Explicit policy for a distributed bridge only. The input count is the actual
/// tokenized prompt; the allowance starts at trusted handler/frame receipt.
/// This is a server deadline, not a measurement of external client TTFT.
public struct DistributedFirstTokenBudgetPolicy: Sendable, Equatable {
    public let baseMilliseconds: Int64
    public let millisecondsPerInputToken: Int64

    public init(baseMilliseconds: Int64, millisecondsPerInputToken: Int64) throws {
        guard baseMilliseconds > 0, millisecondsPerInputToken >= 0 else {
            throw DistributedFirstTokenBudgetError.invalidPolicy
        }
        self.baseMilliseconds = baseMilliseconds
        self.millisecondsPerInputToken = millisecondsPerInputToken
    }

    /// The factory validates its full admitted input range before taking owner
    /// ownership, so valid requests cannot overflow after reserving resources.
    func validate(maximumPromptTokens: Int) throws {
        _ = try milliseconds(inputTokenCount: maximumPromptTokens)
    }

    func restricting(_ context: DistributedRequestDeadlineContext,
                     receivedAt: ContinuousClock.Instant,
                     inputTokenCount: Int) throws -> DistributedRequestDeadlineContext {
        let amount = try milliseconds(inputTokenCount: inputTokenCount)
        let available = receivedAt.duration(to: context.generationDeadline)
        // Clamp the duration before advancing the clock. A very large policy
        // value cannot overflow a clock instant or extend the generation cap.
        let first = available <= .zero ? context.generationDeadline
            : receivedAt.advanced(by: min(.milliseconds(amount), available))
        return context.restricted(to: .init(
            generationDeadline: context.generationDeadline, firstTokenDeadline: first))
    }

    private func milliseconds(inputTokenCount: Int) throws -> Int64 {
        guard inputTokenCount >= 0, let count = Int64(exactly: inputTokenCount) else {
            throw DistributedFirstTokenBudgetError.invalidTokenCount
        }
        let product = millisecondsPerInputToken.multipliedReportingOverflow(by: count)
        let sum = baseMilliseconds.addingReportingOverflow(product.partialValue)
        guard !product.overflow, !sum.overflow else {
            throw DistributedFirstTokenBudgetError.overflow
        }
        return sum.partialValue
    }
}

public enum DistributedFirstTokenBudgetError: Error, Sendable, Equatable {
    case invalidPolicy
    case invalidTokenCount
    case overflow
}
