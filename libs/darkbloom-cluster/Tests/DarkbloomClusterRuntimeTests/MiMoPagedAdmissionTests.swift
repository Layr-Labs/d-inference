import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

@Suite("MiMo paged mode admission bounds (CPU)")
struct MiMoPagedAdmissionTests {
    @Test func targetVerificationWindowIsChargedOnBothRanksWithSmallPrefill() throws {
        let (spec, plan) = try registered()
        for rank in 0...1 {
            for pages in [false, true] {
                let ordinary = try MiMoResidentRequestAllowance.derive(specification: spec, plan: plan, rank: rank,
                    maximumTokens: 4096, chunkSize: 1, independentHistory: pages, bound: { $0 })
                for depth in 1...MiMoMTPTerms.maximumDepth {
                    let width = depth + 1, head = rank == 1 ? 4096 : 0
                    let actual = try MiMoResidentRequestAllowance.derive(specification: spec, plan: plan, rank: rank,
                        maximumTokens: 4096, chunkSize: 1, speculativeBytes: head, independentHistory: pages,
                        verificationTokens: width, bound: { $0 })
                    let target = try MiMoRequestStateBudget.estimate(specification: spec,
                        layers: plan.stages[rank].sourceRange, rank: rank, maximumTokens: 4096,
                        chunkSize: width, bound: { $0 })
                    let pageBytes = pages ? try MiMoPagedKVAllowance.pages(spec: spec,
                        layers: plan.stages[rank].sourceRange, maximumTokens: 4096, chunkSize: width, bound: { $0 }) : 0
                    #expect(actual.budget == target)
                    #expect(actual.pagedBytes == pageBytes && actual.speculativeBytes == head)
                    #expect(actual.reservedBytes == target.reservedBytes + pageBytes + head)
                    #expect(actual.budget.workspaceBytes > ordinary.budget.workspaceBytes)
                    #expect(actual.budget.slidingStateBytes > ordinary.budget.slidingStateBytes)
                    if pages { #expect(actual.pagedBytes > ordinary.pagedBytes) }
                }
                // Normal LOAD prefill already exceeds every draft window.
                let prefill = try MiMoResidentRequestAllowance.derive(specification: spec, plan: plan, rank: rank,
                    maximumTokens: 4096, chunkSize: 512, independentHistory: pages, bound: { $0 })
                let verify = try MiMoResidentRequestAllowance.derive(specification: spec, plan: plan, rank: rank,
                    maximumTokens: 4096, chunkSize: 512, independentHistory: pages, verificationTokens: 4, bound: { $0 })
                #expect(prefill.budget == verify.budget && prefill.pagedBytes == verify.pagedBytes)
            }
        }
    }

    @Test func everyPagedModeKeepsThePreviousAllowanceAndPhaseHandoff() throws {
        let (spec, plan) = try registered()
        let round: (Int) throws -> Int = { $0 + 4096 }
        for mode in [ClusterGenerationMode.pipeline, .pipelineCompactDecode, .pipelineMTP, .phaseSplit] {
            for rank in 0...1 {
                let settings = try MiMoBatchSettings.fromEnvironment([:], mode: mode)
                #expect(settings.lanes == 1 && settings.usesPagedHistory)
                let phase = mode == .phaseSplit
                let ordinary = try MiMoResidentRequestAllowance.derive(specification: spec, plan: plan, rank: rank,
                    maximumTokens: 4096, chunkSize: 512, phaseSplit: phase, bound: round)
                let paged = try MiMoResidentRequestAllowance.derive(specification: spec, plan: plan, rank: rank,
                    maximumTokens: 4096, chunkSize: 512, phaseSplit: phase,
                    independentHistory: settings.usesPagedHistory, bound: round)
                let layers = phase && rank == 1 ? 0..<spec.layers : plan.stages[rank].sourceRange
                let pageBytes = try MiMoPagedKVAllowance.pages(spec: spec, layers: layers,
                    maximumTokens: 4096, chunkSize: 512, bound: round)
                #expect(paged.budget == ordinary.budget && paged.pagedBytes == pageBytes)
                #expect(paged.reservedBytes == ordinary.reservedBytes + pageBytes)
                if phase {
                    let moving = try MiMoRequestStateBudget.estimate(specification: spec, layers: plan.stages[0].sourceRange,
                        rank: 0, maximumTokens: 4096, chunkSize: 512, bound: round)
                    #expect(paged.budget.handoffBytes == moving.fullAttentionStateBytes + moving.slidingStateBytes)
                } else { #expect(paged.budget.handoffBytes == 0) }
            }
        }
    }

    @Test func malformedScopeAndOverflowRefuseBeforeAdmission() throws {
        let (spec, plan) = try registered()
        for invalid in [0, -1, 5, Int.max] {
            #expect(throws: (any Error).self) {
                try MiMoResidentRequestAllowance.derive(specification: spec, plan: plan, rank: 0,
                    maximumTokens: 4096, chunkSize: 1, independentHistory: true,
                    verificationTokens: invalid, bound: { $0 })
            }
        }
        for chunk in [0, -1, 513, Int.max] {
            #expect(throws: (any Error).self) {
                try MiMoResidentRequestAllowance.derive(specification: spec, plan: plan, rank: 0,
                    maximumTokens: 4096, chunkSize: chunk, independentHistory: true,
                    verificationTokens: 4, bound: { $0 })
            }
        }
        for (rank, phase, head, images, verification) in [(0, false, 1, false, 1), (1, true, 1, false, 1),
                (0, true, 0, false, 4), (1, false, 0, true, 1)] {
            #expect(throws: (any Error).self) {
                try MiMoResidentRequestAllowance.derive(specification: spec, plan: plan, rank: rank,
                    maximumTokens: 4096, chunkSize: 1, phaseSplit: phase, speculativeBytes: head,
                    imageCandidate: images, independentHistory: true, verificationTokens: verification, bound: { $0 })
            }
        }
        #expect(throws: (any Error).self) {
            try MiMoResidentRequestAllowance.derive(specification: spec, plan: plan, rank: 1,
                maximumTokens: 4096, chunkSize: 1, speculativeBytes: Int.max, independentHistory: true, bound: { $0 })
        }
        #expect(throws: (any Error).self) {
            try MiMoResidentRequestAllowance.derive(specification: spec, plan: plan, rank: 1,
                maximumTokens: 4096, chunkSize: 1, independentHistory: true, bound: { _ in Int.max })
        }
    }

    private func registered() throws -> (MiMoRegisteredSpecification, MiMoLayerStagePlan) {
        let libs = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let config = try Data(contentsOf: libs.appendingPathComponent(
            "darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/registered-mimo-v26-flash-mopd.configuration.json"))
        let spec = try MiMoRegisteredSpecification.specification(.v26FlashMOPD)
        #expect(sha256(config) == spec.configurationSHA256)
        return (spec, try MiMoLayerStagePlan(configuration: config, cut: 24))
    }
}
