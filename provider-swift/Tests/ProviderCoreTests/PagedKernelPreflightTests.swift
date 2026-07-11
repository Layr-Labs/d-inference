// Copyright © 2026 Eigen Labs.

import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("Paged kernel process preflight", .serialized)
struct PagedKernelPreflightTests {
    init() {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    @Test("child probe sees every model-specific variant before parent pre-JIT")
    func modelSpecificVariants() throws {
        let owner = CBv2LayerKind(
            attention: .full,
            hasSinks: true,
            headDim: 64,
            kvHeads: 8,
            queryHeads: 64)
        var borrower = owner
        borrower.sharesKVWithLayer = 0
        var observed: [PagedAttentionKernelSmokeShape] = []

        try PagedKernelPreflight.run(
            layerKinds: [owner, borrower],
            executableURL: nil,
            childRunner: { observed = $0 })

        #expect(observed.count == 2)
        #expect(observed.contains { $0.hasWrite })
        #expect(observed.contains { !$0.hasWrite })
        #expect(observed.allSatisfy { $0.hasSinks })
    }

    @Test("child crash/failure is catchable and blocks parent construction")
    func childFailureIsCatchable() {
        struct ChildFailure: Error {}
        let kind = CBv2LayerKind(
            attention: .full,
            hasSinks: true,
            headDim: 64,
            kvHeads: 8,
            queryHeads: 64)
        #expect(throws: ChildFailure.self) {
            try PagedKernelPreflight.run(
                layerKinds: [kind],
                executableURL: nil,
                childRunner: { _ in throw ChildFailure() })
        }
    }
}
