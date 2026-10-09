import Foundation

/// What `darkbloom cluster link --fix` would do on this Mac, worked out up to
/// the point where macOS would show its approval prompt and no further.
public struct ClusterLinkFixPreview: Encodable, Sendable, Equatable {
    public let schema: String
    /// True when the fix would reach the macOS approval prompt.
    public let wouldPrompt: Bool
    public let device: String?
    public let interface: String?
    /// The sentence macOS would show the person approving; nil without a prompt.
    public let prompt: String?
    /// What the real command would report where it stops before the prompt,
    /// or what it would ask for. Names only; never the address.
    public let message: String

    init(wouldPrompt: Bool, device: String?, interface: String?, prompt: String?, message: String) {
        schema = "darkbloom_cluster_link_fix_preview_v1"
        self.wouldPrompt = wouldPrompt; self.device = device; self.interface = interface
        self.prompt = prompt; self.message = message
    }

    public var summaryLines: [String] {
        ["Link fix (dry run): " + (wouldPrompt ? "would ask for approval" : "would stop before any prompt"), message]
    }
}

extension ClusterLinkRepair {
    /// The dry run of `fix`: the same inspection, the same choice of port and
    /// the same checks that precede the prompt. It stops there. Nothing is
    /// recorded, no prompt is shown and no setting is read beyond what the
    /// inspection reads.
    public static func previewFix(device: String?) -> ClusterLinkFixPreview {
        previewFix(device: device, run: ClusterLinkReadinessProbe.boundedToolRunner(),
            machineIdentifier: ClusterLinkMachineIdentity.hardwareUUID)
    }

    static func previewFix(device requested: String?, run: ClusterLinkToolRunner,
                           machineIdentifier: () -> String?) -> ClusterLinkFixPreview {
        let report = ClusterLinkReadinessProbe.inspect(run: run)
        func stopped(_ outcome: ClusterLinkRepairOutcome, device: String?, interface: String?,
                     candidates: [String] = []) -> ClusterLinkFixPreview {
            .init(wouldPrompt: false, device: device, interface: interface, prompt: nil,
                message: ClusterLinkRepairResult(operation: .fix, outcome: outcome, device: device, interface: interface,
                    candidates: candidates).message)
        }
        switch ClusterLinkFixPlan.make(for: report, device: requested) {
        case .stop(let outcome):
            let named = report.devices.first { $0.device == requested }
            return stopped(outcome, device: named?.device, interface: named?.interface)
        case .choose(let candidates):
            return stopped(.ambiguousPorts, device: nil, interface: nil, candidates: candidates)
        case .act(let device, let interface):
            // The three things `fix` needs before it may ask, in its order.
            guard ClusterLinkTopology.observe(run: run) != nil else {
                return stopped(.nothingFixable(.probeFailed), device: device, interface: interface)
            }
            guard let machine = machineIdentifier() else {
                return stopped(.machineIdentityUnavailable, device: device, interface: interface)
            }
            let address = ClusterLinkLocalAddress.derived(machineIdentifier: machine, interface: interface)
            guard let command = ClusterLinkAliasCommand(action: .add, interface: interface, address: address) else {
                return stopped(.nothingFixable(.probeFailed), device: device, interface: interface)
            }
            return .init(wouldPrompt: true, device: device, interface: interface, prompt: command.prompt,
                message: "macOS would ask: \"\(command.prompt)\" Nothing was asked, recorded or changed in this dry run.")
        }
    }
}
