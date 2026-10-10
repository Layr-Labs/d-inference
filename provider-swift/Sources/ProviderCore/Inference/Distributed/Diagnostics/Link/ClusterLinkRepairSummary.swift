import Foundation

extension ClusterLinkRepairResult {
    /// Plain sentences for the operator: what happened and what, if anything,
    /// to do next. Names only; never the address.
    public var message: String {
        let port = interface.map { "Thunderbolt port \($0)" } ?? "the Thunderbolt port"
        let rdmaDevice = device ?? "its RDMA device"
        switch outcome {
        case .dryRun:
            return "Dry run: nothing was changed. With your approval in the macOS prompt, these commands would run as an administrator, in this order."
        case .alreadyReady:
            return "The link is already ready; nothing was changed."
        case .alreadyAbsent where isolated == true:
            return "Nothing Darkbloom changed for \(port) is left to undo: its network service is gone, the services it switched off are on and the port is back where it was. Only Darkbloom's record of it is cleared."
        case .alreadyAbsent:
            // Worded for a dry run too, which finds the same and leaves the record as it is.
            return "Nothing Darkbloom gave \(port) is left on this Mac: a temporary address goes when macOS next reconfigures the port or restarts. A removal has nothing to undo and only clears Darkbloom's record of it."
        case .nothingRecorded:
            return "Darkbloom has no record of an address it added there and found no system job of its own; nothing was changed."
        case .fixed where isolated == true:
            let name = interface.map(ClusterLinkServiceName.cluster(interface:)) ?? "Darkbloom's network service"
            return "\(port.prefix(1).uppercased() + port.dropFirst()) now belongs to the cluster alone and \(rdmaDevice) is ready: it has its own network service (\(name)) with a fixed address in \(ClusterLinkClusterAddress.prefix)/16, no router, no DNS and link-local IPv6 only, and it is in no bridge, so Internet Sharing cannot take its address away and nothing else routes through the cable. macOS keeps that address, also after a restart; no Darkbloom job runs. `darkbloom cluster link --remove` restores the previous network settings."
        case .fixed:
            let ready = "\(port.prefix(1).uppercased() + port.dropFirst()) now has a link-local address of its own and \(rdmaDevice) is ready."
            guard durable == true, let interface else {
                return ready + " The address is temporary: macOS removes it when it next reconfigures the port, and at a restart; run `darkbloom cluster` to keep it. `darkbloom cluster link --remove` takes it away."
            }
            return ready + " A system job (\(ClusterLinkAddressKeeper.label(forInterface: interface))) puts the address back within about \(ClusterLinkAddressKeeper.intervalSeconds) seconds whenever macOS leaves the port without an IPv4 address, and after a restart. `darkbloom cluster link --remove` removes the job and the address."
        case .removed where isolated == true:
            return "The network settings of \(port) are as they were before Darkbloom set it up: its network service is removed, the services it switched off are on again, and the port is back in its bridge where it had been in one."
        case .removed:
            return "Everything Darkbloom gave \(port) was removed: its link-local address and, where installed, the system job that kept it."
        case .nothingFixable(let state):
            guard let device else {
                return "Nothing was changed: the link state is \(state.rawValue). " + (state.guidance ?? "The link is ready.")
            }
            // With a port named, `probeFailed` is not that port's condition:
            // its own state, the bridge and route state a fix is verified
            // against, or the listing a removal looks at could not be read.
            guard state != .probeFailed else {
                return "Nothing was changed: Darkbloom could not read the RDMA, interface or route state it needs before acting on \(device); `darkbloom cluster link` shows what it can read."
            }
            return "Nothing was changed: \(device) is \(state.rawValue), which adding an address does not cure; `darkbloom cluster link` shows every port."
        case .ambiguousPorts:
            guard let first = candidates.first else {
                return "More than one port qualifies; choose one with `--device`. Nothing was changed."
            }
            return "More than one port qualifies (\(candidates.joined(separator: ", "))); choose one, for example `darkbloom cluster link --\(operation.rawValue) --device \(first)`. Nothing was changed."
        case .deviceNotListed:
            return "This Mac lists no RDMA device with that name; `darkbloom cluster link` shows the names. Nothing was changed."
        case .machineIdentityUnavailable:
            return "Darkbloom could not read this Mac's hardware identifier, which it uses to choose the address; nothing was changed."
        case .recordUnavailable:
            return "Darkbloom could not read or update its owner-only record of the addresses it adds (~/.darkbloom/cluster-device/link-alias.json); nothing was changed."
        case .approvalDeclined:
            return "The macOS prompt was cancelled; nothing was changed."
        case .approvalUnavailable:
            return "macOS did not grant approval: its prompt could not be shown here, as in an SSH session without a desktop, or it was not answered in time or was refused; nothing was changed. An administrator can run the commands printed on standard error instead."
        case .commandFailed where isolated == true:
            return "The change was approved, but one of its commands reported an error, and the commands after it did not run; run `darkbloom cluster link` to see the current state and `darkbloom cluster link --remove` to restore what was changed."
        case .commandFailed:
            // macOS refuses to start a job that was switched off in Login Items.
            let switchedOff = operation == .fix && durable == true
                ? " If the system job was switched off under System Settings, General, Login Items & Extensions, switch it on there and run `darkbloom cluster` again." : ""
            return "The change was approved, but one of its commands reported an error; run `darkbloom cluster link` to see the current state and `darkbloom cluster link --remove` to undo whatever was done." + switchedOff
        case .appliedButNotReady(let unmet):
            let problems = unmet.map { condition -> String in
                switch condition {
                case .deviceNotReady: return "\(rdmaDevice) is still not ready"
                case .bridgeMembersChanged: return "the bridge member list changed"
                case .defaultRouteChanged: return "the default route now uses a different interface"
                case .stateUnreadable: return "Darkbloom could not read the bridge and route state afterwards"
                case .addressKeeperNotRunning: return "the system job that should keep the address there is not installed and loaded as written"
                }
            }
            return "The change was made to \(port), but \(problems.joined(separator: ", and ")). What was done is still in place; `darkbloom cluster link --remove` takes it away."
        case .isolationRefused(let findings):
            let name = interface ?? "the port"
            let remedies = findings.map { $0.remedy(interface: name, bridge: bridge, hardwarePort: hardwarePort) }
            return "Nothing was changed: " + findings.map { $0.fact(interface: name, bridge: bridge) }.joined(separator: "; ")
                + ". " + (remedies.joined(separator: "; ").prefix(1).uppercased() + remedies.joined(separator: "; ").dropFirst()) + "."
        case .appliedButNotIsolated(let findings):
            let name = interface ?? "the port"
            return "The change was made to \(port), but afterwards " + findings.map { $0.fact(interface: name, bridge: bridge) }.joined(separator: ", ")
                + ". What was done is still in place; `darkbloom cluster link` shows the port and `darkbloom cluster link --remove` restores the previous network settings."
        case .removalNotVerified where isolated == true:
            return "The removal was approved, but Darkbloom could not confirm that the network settings of \(port) are back as they were; run `darkbloom cluster link --remove` again."
        case .removalNotVerified:
            return "The removal was approved, but Darkbloom could not confirm that nothing it gave \(port) is left; run `darkbloom cluster link --remove` again."
        }
    }

    /// The outcome, the message, and for a dry run the commands themselves.
    public var summaryLines: [String] {
        ["Link \(operation.rawValue): \(outcome.code)", message] + plannedCommands.map { "  " + $0 }
    }
}
