import ArgumentParser
import Foundation
import Testing
@testable import darkbloom

@Suite("Autopilot retains the normal startup selector")
struct AutopilotStartupSelectionTests {
    @Test(arguments: [false, true])
    func bothAnswersRunTheNormalSelector(enabled: Bool) async throws {
        var events: [String] = []
        let selection = try await Start.prepareModelSelection(autopilot: enabled, select: {
            events.append("normal selector")
            return ["chosen"]
        }, inventory: { chosen in
            #expect(chosen == ["chosen"])
            events.append("verify inventory")
            return ["chosen", "other-cached"]
        })
        #expect(selection.hostedModels == ["chosen"])
        #expect(selection.autopilotModels == (enabled ? ["chosen", "other-cached"] : nil))
        #expect(events == (enabled ? ["normal selector", "verify inventory"] : ["normal selector"]))
    }

    @Test func cancellingTheNormalSelectorDoesNotVerifyOrEnroll() async {
        await #expect(throws: CancellationError.self) {
            try await Start.prepareModelSelection(autopilot: true,
                select: { throw CancellationError() }, inventory: { _ in
                    Issue.record("Cancelled selection must not start enrollment")
                    return []
                })
        }
    }

    @Test func emptySelectionDoesNotVerifyOrEnroll() async {
        await #expect(throws: (any Error).self) {
            try await Start.prepareModelSelection(autopilot: true,
                select: { [] }, inventory: { _ in
                    Issue.record("Empty selection must not start enrollment")
                    return []
                })
        }
    }

    @Test func selectedModelsMustBeInVerifiedInventory() async {
        await #expect(throws: (any Error).self) {
            try await Start.prepareModelSelection(autopilot: true,
                select: { ["chosen"] }, inventory: { _ in ["other-cached"] })
        }
    }

    /// A local-only startup model (no catalog entry) never enters the
    /// inventory; the error must name it rather than blame a verified model.
    @Test func missingStartupModelsAreNamed() async throws {
        do {
            _ = try await Start.prepareModelSelection(autopilot: true,
                select: { ["ternary-bonsai-2-27b", "prism-ml/Ternary-Bonsai-2-27B-mlx-2bit"] },
                inventory: { _ in ["ternary-bonsai-2-27b"] })
            Issue.record("A startup model outside the inventory must not enroll")
        } catch let error as ValidationError {
            #expect(error.message.contains("Not in the verified inventory: prism-ml/Ternary-Bonsai-2-27B-mlx-2bit."))
            #expect(!error.message.contains("ternary-bonsai-2-27b,"))
        }
    }
}
