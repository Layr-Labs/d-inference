// Copyright © 2026 Eigen Labs.

import Testing

@testable import ProviderCore

@Suite("PagedKV physical capacity policy")
struct PagedKVPhysicalCapacityPolicyTests {
    private let gib = 1 << 30

    private func decision(
        physicalGiB: Int,
        liveGiB: Int,
        logicalGiB: Int = 200,
        rate: Int = 48 * 1024,
        context: Int = 131_072,
        concurrency: Int = 4,
        maxBufferGiB: Int = 32
    ) -> PagedKVPhysicalCapacityPolicy.Decision {
        PagedKVPhysicalCapacityPolicy.decide(
            logicalGrantBytes: logicalGiB * gib,
            fp16BytesPerToken: rate,
            maxContextLength: context,
            maxConcurrentRequests: concurrency,
            inputs: .init(
                physicalMemoryBytes: UInt64(physicalGiB * gib),
                liveKVHeadroomBytes: UInt64(liveGiB * gib),
                maxBufferLength: maxBufferGiB * gib))
    }

    @Test("32/64/128/256 GiB hosts stay useful without scaling to the logical grant")
    func machineSizingMatrix() {
        let cases = [
            (physical: 32, live: 16, expectedGiB: 2),
            (physical: 64, live: 32, expectedGiB: 4),
            (physical: 128, live: 64, expectedGiB: 6),
            (physical: 256, live: 128, expectedGiB: 6),
        ]
        for item in cases {
            guard case .paged(let plan) = decision(
                physicalGiB: item.physical,
                liveGiB: item.live)
            else {
                Issue.record("\(item.physical) GiB host unexpectedly fell back")
                continue
            }
            #expect(plan.capacityBytes == item.expectedGiB * gib)
            #expect(plan.capacityBytes < 200 * gib)
            #expect(plan.capacityBytes <= PagedKVPhysicalCapacityPolicy.absoluteHardCapBytes)
        }
    }

    @Test("live memory and maxBufferLength can force a pre-allocation contiguous fallback")
    func resourceLimitsFailClosed() {
        #expect(
            decision(physicalGiB: 128, liveGiB: 3)
                == .contiguous(
                    reason: "physical_capacity: safe pool 805306368 B is below "
                        + "the 1073741824 B serviceability floor"))
        #expect(
            decision(
                physicalGiB: 128,
                liveGiB: 64,
                maxBufferGiB: 0)
                == .contiguous(
                    reason: "physical_capacity: Metal maxBufferLength unavailable"))
    }

    @Test("mixed-model load order remains bounded by live and machine caps")
    func mixedModelLoadOrders() {
        let rates = [48 * 1024, 32 * 1024]

        func loadOrder(_ order: [Int]) -> [Int] {
            var live = 40 * gib
            var pools: [Int] = []
            for index in order {
                let result = PagedKVPhysicalCapacityPolicy.decide(
                    logicalGrantBytes: 40 * gib,
                    fp16BytesPerToken: rates[index],
                    maxContextLength: 131_072,
                    maxConcurrentRequests: 4,
                    inputs: .init(
                        physicalMemoryBytes: UInt64(64 * gib),
                        liveKVHeadroomBytes: UInt64(live),
                        maxBufferLength: 32 * gib))
                guard case .paged(let plan) = result else {
                    Issue.record("mixed-model load \(index) unexpectedly fell back")
                    continue
                }
                pools.append(plan.capacityBytes)
                live -= plan.capacityBytes
            }
            return pools
        }

        let gptThenGemma = loadOrder([0, 1])
        let gemmaThenGPT = loadOrder([1, 0])
        #expect(gptThenGemma.reduce(0, +) == 8 * gib)
        #expect(gemmaThenGPT.reduce(0, +) == 8 * gib)
        #expect((gptThenGemma + gemmaThenGPT).allSatisfy { $0 <= 4 * gib })
    }
}
