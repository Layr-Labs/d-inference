import Testing
@testable import ProviderCore

@Test func globalKVCacheBudgetRejectsDuplicateReservationIDs() async {
    let budget = GlobalKVCacheBudget(safetyFactor: 1.0) {
        (total: 1024, active: 0, cache: 0)
    }

    #expect(await budget.reserve(requestID: "same", kvBytesPerToken: 1, tokenCount: 1))
    #expect(!(await budget.reserve(requestID: "same", kvBytesPerToken: 1, tokenCount: 1)))

    await budget.release(requestID: "same")
    #expect(await budget.reserve(requestID: "same", kvBytesPerToken: 1, tokenCount: 1))
}

@Test func globalKVCacheBudgetRejectsOverflowingReservationSize() async {
    let budget = GlobalKVCacheBudget(safetyFactor: 1.0) {
        (total: UInt64.max, active: 0, cache: 0)
    }

    #expect(!(await budget.reserve(requestID: "overflow", kvBytesPerToken: Int.max, tokenCount: Int.max)))
}

@Test func globalKVCacheBudgetHonorsSafetyFactorAsTotalReservationCap() async {
    let budget = GlobalKVCacheBudget(safetyFactor: 0.5) {
        (total: 1000, active: 0, cache: 0)
    }

    #expect(await budget.reserve(requestID: "first", kvBytesPerToken: 1, tokenCount: 400))
    #expect(!(await budget.reserve(requestID: "second", kvBytesPerToken: 1, tokenCount: 200)))
}

@Test func providerLoopMemoryReserveBytesSaturatesOnOverflow() {
    #expect(ProviderLoop.memoryReserveBytes(forGiB: 4) == 4 * 1024 * 1024 * 1024)
    #expect(ProviderLoop.memoryReserveBytes(forGiB: UInt64.max) == UInt64.max)
}
