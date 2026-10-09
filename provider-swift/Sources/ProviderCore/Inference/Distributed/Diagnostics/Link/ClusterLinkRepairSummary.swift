import Foundation

extension ClusterLinkRepairResult {
    /// Plain sentences for the operator: what happened and what, if anything,
    /// to do next. Names only; never the address.
    public var message: String {
        let port = interface.map { "Thunderbolt port \($0)" } ?? "the Thunderbolt port"
        let rdmaDevice = device ?? "its RDMA device"
        switch outcome {
        case .alreadyReady:
            return "The link is already ready; nothing was changed."
        case .alreadyAbsent:
            return "The link-local address Darkbloom gave \(port) was already gone, as happens after a restart or a cable replug; its record was cleared."
        case .nothingRecorded:
            return "Darkbloom has no record of an address it added there; nothing was changed."
        case .fixed:
            return "\(port.prefix(1).uppercased() + port.dropFirst()) now has a link-local address of its own and \(rdmaDevice) is ready. The address does not survive a restart or a cable replug: run `darkbloom cluster link --fix` again afterwards. `darkbloom cluster link --remove` takes it away."
        case .removed:
            return "The link-local address Darkbloom gave \(port) was removed."
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
            return "macOS did not grant approval: its prompt could not be shown here, as in an SSH session without a desktop, or it was not answered in time or was refused; nothing was changed. An administrator can run the one command printed on standard error instead."
        case .commandFailed:
            return "The change was approved, but `ifconfig` reported an error; run `darkbloom cluster link` to see the current state."
        case .appliedButNotReady(let unmet):
            let problems = unmet.map { condition -> String in
                switch condition {
                case .deviceNotReady: return "\(rdmaDevice) is still not ready"
                case .bridgeMembersChanged: return "the bridge member list changed"
                case .defaultRouteChanged: return "the default route now uses a different interface"
                case .stateUnreadable: return "Darkbloom could not read the bridge and route state afterwards"
                }
            }
            return "The address was added to \(port), but \(problems.joined(separator: ", and ")). It is still in place; `darkbloom cluster link --remove` takes it away."
        case .removalNotVerified:
            return "The removal was approved, but Darkbloom could not confirm that \(port) no longer carries the address; run `darkbloom cluster link --remove` again."
        }
    }

    public var summaryLines: [String] {
        ["Link \(operation.rawValue): \(outcome.code)", message]
    }
}
