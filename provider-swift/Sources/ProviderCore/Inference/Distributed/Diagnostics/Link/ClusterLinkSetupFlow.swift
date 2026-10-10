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
        /// Read the link state again for up to `keeperWaitSeconds`, until it
        /// changes, and report the last reading with `observed`.
        case awaitKeeper
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
    /// The address alone, without the job that keeps it there.
    public let temporary: Bool
    /// Work out what an approval would run, and run nothing.
    public let dryRun: Bool
    /// The link state last observed.
    public private(set) var linkState: ClusterLinkReadinessState?
    private var rdmaReported = false
    private var waitReported = false
    /// The fix was asked for a port that is ready already, only to install
    /// the job that keeps its address.
    private var keepingOnly = false
    /// The fix asked for is link setup v2: the port gets its own network service.
    private var isolating = false
    private var keeperAwaited = false
    /// The active ports last named, so a second look at the same ones is not narrated twice.
    private var portsReported = [String]()

    /// One run of the keeper and a little more.
    public static let keeperWaitSeconds = ClusterLinkAddressKeeper.intervalSeconds + 4

    /// In a terminal the prompt is part of the flow. Anywhere else, and
    /// whenever JSON is asked for, it needs an explicit `--yes`.
    public static func mayPrompt(standardOutputIsTerminal: Bool, json: Bool, yes: Bool) -> Bool {
        yes || (standardOutputIsTerminal && !json)
    }

    public init(mayPrompt: Bool, temporary: Bool = false, dryRun: Bool = false) {
        self.mayPrompt = mayPrompt
        self.temporary = temporary
        self.dryRun = dryRun
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
            // A dry run reports what it finds; it does not sit and wait.
            guard mayPrompt, !dryRun else {
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
        if ports != portsReported {
            portsReported = ports
            lines.append("Connection detected: \(ports.joined(separator: ", ")) \(ports.count == 1 ? "is" : "are") active.")
        }

        // Address: the same decision `cluster link --fix` makes.
        switch ClusterLinkFixPlan.make(for: report, device: nil, keeping: !temporary) {
        case .stop(.alreadyReady):
            let ready = active.first { $0.verdict == .ready }
            let port = ready.map { ClusterLinkName.label(device: $0.device, interface: $0.interface) } ?? "The active port"
            let address = ready?.interfaceHasIPv4Address == true ? "has its own IPv4 address and " : ""
            var found = ["Address ready: \(port) \(address)publishes the GID RDMA needs."]
            if ready?.isolation?.isolated == true, let interface = ready?.interface {
                found.append(Self.isolatedSentence(interface: interface))
            } else if ready?.assignedAddress == .present, ready?.addressKept == true, let interface = ready?.interface {
                found.append("A system job (\(ClusterLinkAddressKeeper.label(forInterface: interface))) keeps that address there.")
            } else if ready?.addressIsTemporary == true {
                found.append(Self.temporaryAddress)
            }
            return finished(lines + found)
        case .act(let device, let interface):
            let port = report.devices.first { $0.device == device }
            let next = "Next: run `darkbloom cluster` in a terminal on this Mac and approve the macOS prompt, or add `--yes` to allow the prompt from here."
            // Link setup v2: the port is not isolated. Said the same way whether
            // it is ready or lacks its address, since the one change cures both.
            if !temporary, let port, port.isolationApplies, let isolation = port.isolation {
                isolating = true
                keepingOnly = port.verdict == .ready
                let found = port.verdict == .ready
                    ? "Address ready: \(ClusterLinkName.label(device: device, interface: interface)) publishes the GID RDMA needs, but the port is \(isolation.facts(interface: interface))"
                    : "Thunderbolt port \(interface) has no IPv4 address of its own, which RDMA needs, and is \(isolation.facts(interface: interface))"
                if dryRun { return Step(lines: lines + [found + "."], action: .fix(device: device)) }
                // What the approval cannot cure is said before any prompt; the fix stops on it too.
                guard isolation.blockers.isEmpty else { return Step(lines: lines + [found + "."], action: .fix(device: device)) }
                guard mayPrompt else { return port.verdict == .ready ? finished(lines + [found + ".", next]) : stopped(lines + [found + ".", next]) }
                return Step(lines: lines + [found + ", so Darkbloom will give it its own network service with a fixed address, no router and no DNS, outside every bridge, which macOS keeps there also after a restart; approve the macOS prompt to continue."],
                    action: .fix(device: device))
            }
            // A ready port is here only because nothing keeps the address Darkbloom gave it.
            if port?.verdict == .ready {
                keepingOnly = true
                let found = "Address ready: \(ClusterLinkName.label(device: device, interface: interface)) publishes the GID RDMA needs, but nothing keeps its address there and macOS removes it when it next reconfigures the port"
                if dryRun { return Step(lines: lines + [found + "."], action: .fix(device: device)) }
                guard mayPrompt else { return finished(lines + [found + ".", next]) }
                return Step(lines: lines + [found + ", so Darkbloom will install a small system job that keeps it there; approve the macOS prompt to continue."],
                    action: .fix(device: device))
            }
            // Said differently when the port lacks an address Darkbloom has on record for it.
            let lost = port?.assignedAddress == .missing
            let missing = lost ? "Thunderbolt port \(interface) does not have the address Darkbloom has on record for it, which RDMA needs"
                : "Thunderbolt port \(interface) has no IPv4 address of its own, which RDMA needs"
            // A dry run goes on to work out the commands; it opens no prompt.
            if dryRun { return Step(lines: lines + [missing + "."], action: .fix(device: device)) }
            // The job that keeps the address is running, so it is about to
            // put the address back by itself: that is waited for once, with
            // no prompt, before anything is installed again.
            let keeperRunning = lost && port?.addressKept == true
            if keeperRunning, !keeperAwaited {
                keeperAwaited = true
                return Step(lines: lines + ["\(missing); its system job (\(ClusterLinkAddressKeeper.label(forInterface: interface))) puts it there within about \(ClusterLinkAddressKeeper.intervalSeconds) seconds. Waiting for it…"],
                    action: .awaitKeeper)
            }
            guard mayPrompt else { return stopped(lines + [missing + ".", next]) }
            let action = lost ? "put it there" : "give it a link-local one"
            let duration = temporary ? (lost ? " until macOS next removes it" : " that lasts until macOS next removes it")
                : keeperRunning ? " and install its system job afresh" : " and install a small system job that keeps it there"
            return Step(lines: lines + ["\(missing), so Darkbloom will \(action)\(duration); approve the macOS prompt to continue."],
                action: .fix(device: device))
        case .choose(let candidates):
            let choose = "(\(candidates.joined(separator: ", "))); choose one with `darkbloom cluster link --fix --device \(candidates[0])`."
            // Ready ports are candidates only for the job that keeps their address.
            guard report.state == .ready else { return stopped(lines + ["More than one active port lacks an address " + choose]) }
            return finished(lines + ["More than one active port has an address that nothing keeps " + choose])
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
            let lasting: String
            if result.isolated == true, let interface = result.interface {
                lasting = Self.isolatedSentence(interface: interface) + " `darkbloom cluster link --remove` restores the previous network settings."
            } else if result.durable == true, let interface = result.interface {
                lasting = "A system job (\(ClusterLinkAddressKeeper.label(forInterface: interface))) puts the address back whenever macOS removes it, also after a restart; `darkbloom cluster link --remove` removes both."
            } else {
                lasting = Self.temporaryAddress
            }
            // A port that was ready before had its address already.
            return finished(keepingOnly ? [lasting] : ["Address assigned: \(port) now publishes the GID RDMA needs.", lasting])
        case .dryRun:
            return Step(lines: [result.message] + result.plannedCommands.map { "  " + $0 }, action: .finish(exitCode: 0))
        case .alreadyReady:
            linkState = .ready
            return finished(["Address ready: \(port) publishes the GID RDMA needs."])
        case .approvalDeclined where keepingOnly, .approvalUnavailable where keepingOnly:
            // Nothing was taken away: a port that was ready still is.
            let unanswered = result.outcome == .approvalDeclined ? "The macOS prompt was cancelled"
                : "The macOS prompt could not be shown or was not answered here"
            if isolating {
                return finished(["\(unanswered), so the port is not isolated yet; run `darkbloom cluster` in a terminal on this Mac and approve the prompt to isolate it."])
            }
            return finished(["\(unanswered), so nothing keeps the address yet; run `darkbloom cluster` in a terminal on this Mac and approve the prompt to keep it."])
        case .isolationRefused where keepingOnly:
            // The link works as it is; only the isolation has to wait for the owner.
            return finished([result.message])
        case .approvalDeclined:
            let again = temporary ? "Run `darkbloom cluster --temporary` again and approve the prompt to finish."
                : "Run `darkbloom cluster` again and approve the prompt to finish; `darkbloom cluster --temporary` adds the address without installing anything, until macOS next removes it."
            return stopped(["The macOS prompt was cancelled, so this link cannot be used yet.", again],
                exitCode: result.outcome.exitCode)
        default:
            // After a change that left the port not ready, the last reading no longer holds.
            if case .appliedButNotReady(let unmet) = result.outcome, unmet.contains(.deviceNotReady) { linkState = nil }
            return stopped([result.message], exitCode: result.outcome.exitCode)
        }
    }

    /// The person stopped the wait for a connection.
    public mutating func interrupted() -> Step {
        stopped(["Stopped before a connection was detected; run `darkbloom cluster` again once the cable is connected."])
    }

    /// What an isolated port has, in one sentence.
    static func isolatedSentence(interface: String) -> String {
        "Isolated: Thunderbolt port \(interface) has its own network service (\(ClusterLinkServiceName.cluster(interface: interface))) with a fixed address, no router and no DNS, outside every bridge; macOS keeps that address, also after a restart, and nothing else routes through the cable."
    }

    private static let temporaryAddress = "The address is temporary: macOS removes it when it next reconfigures the port, and at a restart; run `darkbloom cluster` to keep it."

    private func finished(_ lines: [String]) -> Step {
        // Pairing and model steps are not part of this flow; only what is true is said.
        Step(lines: lines + ["This Mac's link is ready.", "Run `darkbloom cluster` on the other Mac too."],
            action: .finish(exitCode: 0))
    }

    /// Every ending that is neither `finished` nor a dry run's plan. Those two
    /// alone carry status 0, whatever status a repair outcome has.
    private func stopped(_ lines: [String], exitCode: Int32 = 1) -> Step {
        Step(lines: lines, action: .finish(exitCode: max(exitCode, 1)))
    }
}

/// What `darkbloom cluster --json` prints once the flow ends. Names and
/// sentences only: an address appears nowhere but in the command lines that
/// a dry run narrates.
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
