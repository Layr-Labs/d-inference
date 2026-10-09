import Foundation

/// The guided `darkbloom cluster` flow as a state machine: RDMA, connection,
/// address, done. It decides and words every step from what was observed and
/// performs nothing itself; the command line runs the inspection, the wait
/// and the approval-gated fix it asks for, and feeds the results back in.
public struct ClusterLinkSetupFlow: Sendable, Equatable {
    public enum Action: Equatable, Sendable {
        /// Read the link state once and report it with `observed`.
        case inspect
        /// Watch until the link changes, then report it with `observed`, or
        /// call `interrupted` if the person stops the wait.
        case awaitConnection
        /// Run `ClusterLinkRepair.fix` for this device and report it with `repaired`.
        case fix(device: String)
        case finish(exitCode: Int32)
    }

    public struct Step: Equatable, Sendable {
        /// What to tell the person now, one observation per line.
        public let lines: [String]
        public let action: Action
    }

    /// Whether the flow may wait for a cable and open the macOS prompt by
    /// itself. Without it the flow only says what it found and what is next.
    public let mayPrompt: Bool
    /// The link state last observed.
    public private(set) var linkState: ClusterLinkReadinessState?
    private var rdmaReported = false
    private var waitReported = false

    /// In a terminal the prompt is part of the flow. Anywhere else, and
    /// whenever JSON is asked for, it needs an explicit `--yes`.
    public static func mayPrompt(standardOutputIsTerminal: Bool, json: Bool, yes: Bool) -> Bool {
        yes || (standardOutputIsTerminal && !json)
    }

    public init(mayPrompt: Bool) {
        self.mayPrompt = mayPrompt
    }

    public func begin() -> Step {
        Step(lines: [], action: .inspect)
    }

    public mutating func observed(_ report: ClusterLinkReadinessReport) -> Step {
        linkState = report.state
        // RDMA: no device listing means it is off, missing, or unreadable.
        guard !report.devices.isEmpty else { return stopped([report.state.guidance].compactMap { $0 }) }
        var lines = [String]()
        if !rdmaReported {
            rdmaReported = true
            lines.append("RDMA setup detected: RDMA over Thunderbolt is enabled on this Mac.")
        }

        // Connection.
        let active = report.devices.filter(\.portActive)
        guard !active.isEmpty else {
            guard mayPrompt else {
                return stopped(lines + ["No Thunderbolt 5 connection to another Mac is active.",
                    "Next: connect the two Macs with a Thunderbolt 5 cable, then run `darkbloom cluster` again."])
            }
            if !waitReported {
                waitReported = true
                lines.append("Waiting for a Thunderbolt 5 connection to another Mac…")
            }
            return Step(lines: lines, action: .awaitConnection)
        }
        let ports = active.map { ClusterLinkName.label(device: $0.device, interface: $0.interface) }
        lines.append("Connection detected: \(ports.joined(separator: ", ")) \(ports.count == 1 ? "is" : "are") active.")

        // Address: the same decision `cluster link --fix` makes.
        switch ClusterLinkFixPlan.make(for: report, device: nil) {
        case .stop(.alreadyReady):
            let ready = active.first { $0.verdict == .ready }
            let port = ready.map { ClusterLinkName.label(device: $0.device, interface: $0.interface) } ?? "The active port"
            let address = ready?.interfaceHasIPv4Address == true ? "has its own IPv4 address and " : ""
            return finished(lines + ["Address ready: \(port) \(address)publishes the GID RDMA needs."])
        case .act(let device, let interface):
            let missing = "Thunderbolt port \(interface) has no IPv4 address of its own, which RDMA needs"
            guard mayPrompt else {
                return stopped(lines + [missing + ".",
                    "Next: run `darkbloom cluster` in a terminal on this Mac and approve the macOS prompt, or add `--yes` to allow the prompt from here."])
            }
            return Step(lines: lines + [missing + ", so Darkbloom will give it a link-local one; approve the macOS prompt to continue."],
                action: .fix(device: device))
        case .choose(let candidates):
            return stopped(lines + ["More than one active port lacks an address (\(candidates.joined(separator: ", "))); choose one with `darkbloom cluster link --fix --device \(candidates[0])`."])
        case .stop(.nothingFixable(let state)):
            return stopped(lines + [state.guidance].compactMap { $0 })
        case .stop(let outcome):
            return stopped(lines + [ClusterLinkRepairResult(operation: .fix, outcome: outcome).message])
        }
    }

    public mutating func repaired(_ result: ClusterLinkRepairResult) -> Step {
        let port = result.device.map { ClusterLinkName.label(device: $0, interface: result.interface) } ?? "The port"
        switch result.outcome {
        case .fixed:
            linkState = .ready
            return finished(["Address assigned: \(port) now publishes the GID RDMA needs.",
                "The address is lost at a restart or when the cable is replugged; run `darkbloom cluster` again then."])
        case .alreadyReady:
            linkState = .ready
            return finished(["Address ready: \(port) publishes the GID RDMA needs."])
        case .approvalDeclined:
            return stopped(["The macOS prompt was cancelled, so this link cannot be used yet.",
                "Run `darkbloom cluster` again and approve the prompt to finish."], exitCode: result.outcome.exitCode)
        default:
            return stopped([result.message], exitCode: result.outcome.exitCode)
        }
    }

    /// The person stopped the wait for a connection.
    public mutating func interrupted() -> Step {
        stopped(["Stopped before a connection was detected; run `darkbloom cluster` again once the cable is connected."])
    }

    private func finished(_ lines: [String]) -> Step {
        // Pairing and model steps are not part of this flow; only what is true is said.
        Step(lines: lines + ["This Mac's link is ready.", "Run `darkbloom cluster` on the other Mac too."],
            action: .finish(exitCode: 0))
    }

    /// Every ending but `finished`. Status 0 means the link is ready, so no
    /// other ending carries it, whatever status a repair outcome has.
    private func stopped(_ lines: [String], exitCode: Int32 = 1) -> Step {
        Step(lines: lines, action: .finish(exitCode: max(exitCode, 1)))
    }
}

/// What `darkbloom cluster --json` prints once the flow ends. Names and
/// sentences only; never an address.
public struct ClusterLinkSetupResult: Encodable, Sendable, Equatable {
    public let schema = "darkbloom_cluster_setup_v1"
    public let ready: Bool
    public let state: ClusterLinkReadinessState?
    /// The lines the flow would have printed, in order.
    public let narration: [String]

    public init(ready: Bool, state: ClusterLinkReadinessState?, narration: [String]) {
        self.ready = ready
        self.state = state
        self.narration = narration
    }
}
