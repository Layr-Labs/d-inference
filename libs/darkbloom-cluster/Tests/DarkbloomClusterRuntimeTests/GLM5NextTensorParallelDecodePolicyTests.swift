import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

/// The GLM tensor-parallel decode policy (`GLM5NextTensorParallelDecodePolicy`),
/// model-free: its switches, its load agreement, its windows, and the lane
/// loop running it on both ranks.
struct GLM5NextTensorParallelDecodePolicyTests {
    typealias Policy = GLM5NextTensorParallelDecodePolicy
    typealias Switches = ClusterGLMTensorParallel

    /// No switch is today's decode: the fixed depth cut at the output limit,
    /// one-row windows unpadded, and nothing added to the load agreement.
    @Test func theDefaultIsTodaysDecode() throws {
        let policy = try Policy(environment: [:])
        #expect(policy == .fixed && !policy.widthInvariant && policy.loadAgreementFields.isEmpty)
        for lanes in 1...8 {
            for left in 1...5 {
                #expect(policy.window(maximum: 2, lanes: lanes, outputLeft: left) == min(2, left - 1))
            }
        }
        // A lane threshold alone changes nothing.
        #expect(try Policy(environment: [Switches.loadLanesSwitch: "5"]) == .fixed)
        #expect(try Policy(environment: [Switches.depthPolicySwitch: "fixed",
            Switches.widthInvariantSwitch: "0"]) == .fixed)
    }

    @Test func switchesParseAndRefuseOtherValues() throws {
        let load = try Policy(environment: [Switches.depthPolicySwitch: "load"])
        #expect(load.depth == .load && load.loadLanes == 3 && load.widthInvariant, "load pads one-row windows")
        let four = try Policy(environment: [Switches.depthPolicySwitch: "load", Switches.loadLanesSwitch: "4"])
        #expect(four.loadLanes == 4)
        let padded = try Policy(environment: [Switches.widthInvariantSwitch: "1"])
        #expect(padded.depth == .fixed && padded.widthInvariant)
        for (name, value) in [(Switches.depthPolicySwitch, "acceptance"), (Switches.depthPolicySwitch, "LOAD"),
                              (Switches.loadLanesSwitch, "1"), (Switches.loadLanesSwitch, "9"),
                              (Switches.widthInvariantSwitch, "yes")] {
            #expect(throws: ProbeError.self, "\(name)=\(value)") { try Policy(environment: [name: value]) }
        }
    }

    /// Each setting has its own agreement fields: two ranks set differently do not load together.
    @Test func everySettingIsItsOwnAgreement() throws {
        let settings = [Policy.fixed, Policy(widthInvariant: true), Policy(depth: .load),
                        Policy(depth: .load, loadLanes: 4)]
        let fields = settings.map(\.loadAgreementFields)
        #expect(Set(fields.map { $0.joined(separator: "|") }).count == settings.count)
        #expect(fields[2] == ["glm5-next-tp-decode-policy-v1", "load", "load-lanes=3", "padded"])
    }

    /// `load`: the full depth while fewer lanes than the threshold decode in
    /// a step, one proposal from it; always cut at the output limit, and a
    /// request's last token is a window of none (verified padded).
    @Test func theLoadPolicyVerifiesOneProposalFromItsLaneCount() {
        let policy = Policy(depth: .load, loadLanes: 3)
        #expect(policy.depth(maximum: 2, lanes: 1) == 2 && policy.depth(maximum: 2, lanes: 2) == 2)
        #expect((3...8).allSatisfy { policy.depth(maximum: 2, lanes: $0) == 1 })
        #expect(policy.window(maximum: 2, lanes: 2, outputLeft: 2) == 1)
        #expect(policy.window(maximum: 2, lanes: 2, outputLeft: 1) == 0)
        #expect(policy.window(maximum: 2, lanes: 4, outputLeft: 9) == 1)
        #expect(policy.window(maximum: 2, lanes: 4, outputLeft: 1) == 0)
        #expect(Policy(depth: .load, loadLanes: 2).depth(maximum: 2, lanes: 2) == 1)
    }

    /// The owner forwards only known switches with values they take.
    @Test func theOwnerForwardsOnlyKnownSwitchValues() {
        let environment = [Switches.depthPolicySwitch: "load", Switches.loadLanesSwitch: "12",
                           Switches.widthInvariantSwitch: "1", "DARKBLOOM_GLM_TP_OTHER": "1", "PATH": "/bin"]
        #expect(Switches.forwardedDecodeSwitches(environment)
            == [Switches.depthPolicySwitch: "load", Switches.widthInvariantSwitch: "1"])
        #expect(Switches.forwardedDecodeSwitches([:]).isEmpty)
    }

    // MARK: The two-rank lane loop

    /// Both ranks run `load`: every round verifies the policy's window for
    /// the units of its step (rank 1 checks each against its own), so lanes
    /// verify one proposal while three or more decode and two otherwise;
    /// every lane still publishes its solo tokens.
    @Test func theLaneLoopRunsTheLoadPolicyOnBothRanks() throws {
        let run = try FakePair(lanes: 4)
        for native in run.natives { native.policy = Policy(depth: .load, loadLanes: 3) }
        // Even prompts speculate (`FakeLaneNative.speculates`); arrivals and
        // output limits vary the lanes decoding at once from one to four.
        let specs: [FakePair.Spec] = [
            .init(tick: 0, prompt: 6, output: 40), .init(tick: 2, prompt: 4, output: 9),
            .init(tick: 3, prompt: 8, output: 30), .init(tick: 4, prompt: 2, output: 14),
            .init(tick: 30, prompt: 10, output: 11),
        ]
        try run.serve(specs)
        for (index, spec) in specs.enumerated() {
            #expect(run.hosts[0].record(run.ids[index]).tokens
                == FakeLaneNative.solo(prompt: run.prompts[index], count: spec.output), "lane \(index) solo tokens")
        }
        let windows = run.natives[0].windows
        let policy = Policy(depth: .load, loadLanes: 3)
        #expect(windows.allSatisfy { $0.window == policy.window(maximum: 2, lanes: $0.lanes, outputLeft: $0.outputLeft) })
        #expect(windows.contains { $0.lanes >= 3 && $0.window == 1 }, "busy steps verify one proposal")
        #expect(windows.contains { $0.lanes < 3 && $0.window == 2 }, "quiet steps verify two")
        #expect(windows.map(\.window) == run.natives[1].windows.map(\.window))
        #expect(run.link.mismatch == nil)
    }

    /// Ranks set to different policies stop at the first step whose windows differ.
    @Test func ranksWithDifferentPoliciesStop() throws {
        let run = try FakePair(lanes: 4)
        run.natives[0].policy = Policy(depth: .load, loadLanes: 3)
        // Long enough that three lanes decode together.
        let specs: [FakePair.Spec] = (0..<4).map { .init(tick: 0, prompt: 2 * ($0 + 1), output: 48) }
        #expect(throws: (any Error).self) { try run.serve(specs) }
        #expect(run.natives[1].windows.allSatisfy { $0.lanes < 3 }, "rank 1 ran no step rank 0 planned at depth 1")
    }
}
