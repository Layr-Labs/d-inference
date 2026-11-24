import Foundation
import Testing
@testable import ProviderCore

/// A request whose paged pool cannot be reserved ends with the SDK's
/// `capacityExhausted(needed:available:)` text. It is retryable capacity
/// (the capacity code), not an untyped generation failure (500).
@Suite("Paged pool refusal is capacity")
struct PagedPoolRefusalMappingTests {
    @Test func aPagedPoolRefusalIsRetryableCapacity() {
        let message = "capacityExhausted(needed: 206929821, available: 205979648)"
        let error = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message)
        #expect(error == .tokenBudgetExhausted(message))
        #expect(ProviderLoop.sanitizedInferenceFailure(from: error, phase: .generation).statusCode != 500)
    }
}
