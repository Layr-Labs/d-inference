import Foundation
import Testing
@testable import ProviderCore

@Suite struct DistributedServingEligibilityTests {
    private let families: [ChipFamily] = [.m1, .m2, .m3, .m4, .m5, .m6, .unknown]

    /// A control-only member never reports a kernel capability, on any chip.
    @Test func memberNeverReportsAKernelCapability() {
        for family in families {
            let reported = DistributedServingEligibility.memberCapabilities(chipFamily: family)
            #expect(!reported.contains(.mlxNAX))
            #expect(reported.isSubset(of: [.appleM5]))
        }
        #expect(DistributedServingEligibility.memberCapabilities(chipFamily: .m5) == [.appleM5])
    }

    /// The gate is `ModelRuntimeRequirements`; this entry adds an explanation, not a rule.
    @Test func decisionIsTheUnchangedModelEligibilityGate() throws {
        let models = Array(ModelRuntimeRequirements.qwen38ConcreteModelIDs) + ["Qwen3.5-9B", "fixture/public-model"]
        let sets: [Set<ProviderRuntimeCapability>] = [[], [.appleM5], [.mlxNAX], [.appleM5, .mlxNAX], [.modelRevisions]]
        for model in models {
            for capabilities in sets {
                let expected = ModelRuntimeRequirements.isEligible(modelID: model, available: capabilities)
                var accepted = true
                do { try DistributedServingEligibility.require(modelID: model, memberCapabilities: capabilities) } catch { accepted = false }
                #expect(accepted == expected, "\(model) with \(capabilities.map(\.rawValue).sorted())")
            }
        }
    }

    /// No Mac's member can serve the 27B on a pair, and the refusal says why.
    @Test func twentySevenBIsRefusedForEveryMemberWithItsReason() throws {
        for model in ModelRuntimeRequirements.qwen38ConcreteModelIDs {
            for family in families {
                let member = DistributedServingEligibility.memberCapabilities(chipFamily: family)
                do {
                    try DistributedServingEligibility.require(modelID: model, memberCapabilities: member)
                    Issue.record("\(model) was accepted for a \(family.rawValue) member")
                } catch let refusal as DistributedServingIneligibleError {
                    let text = refusal.description
                    #expect(refusal.eligibility.missing.contains(.mlxNAX))
                    #expect(text.contains(model) && text.contains("mlx_nax") && text.contains("policy decision"))
                    #expect(text.contains("reports its chip class only") && text.contains("no cluster setting changes it"))
                    // The gate's own sentence is kept in front of the explanation.
                    #expect(text.hasPrefix(ModelRuntimeIneligibleError(eligibility: refusal.eligibility).errorDescription ?? "?"))
                    #expect(refusal.errorDescription == text)
                }
            }
        }
        // The pair's ordinary model is not affected.
        try DistributedServingEligibility.require(modelID: "Qwen3.5-9B", memberCapabilities: [])
    }
}
